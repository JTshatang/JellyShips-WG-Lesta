using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using NAudio.Wave;

public sealed class SongBeatCandidate
{
    public double Bpm { get; private set; }
    public int DrumFrame { get; private set; }
    public bool Uncertain { get; private set; }
    public int? SuspectFrame { get; private set; }

    internal SongBeatCandidate(double bpm, int drumFrame, bool uncertain, int? suspectFrame)
    {
        Bpm = bpm;
        DrumFrame = drumFrame;
        Uncertain = uncertain;
        SuspectFrame = suspectFrame;
    }
}

public sealed class SongBeatAnalysis
{
    private const int HopFrames = 240;
    private const int HopsPerSecond = BeatSchedule.SampleRate / HopFrames;
    private const int SectionHops = 12 * HopsPerSecond;
    private const int MinPeriod = 50;  // 240 BPM
    private const int MaxPeriod = 218; // About 55 BPM
    private const int PhaseTolerance = 9; // 45 ms

    public SongBeatCandidate[] Candidates { get; private set; }
    private SongBeatAnalysis(SongBeatCandidate[] candidates)
    {
        Candidates = candidates;
    }

    public static Task<SongBeatAnalysis> Start(string decodedPath)
    {
        return Task.Run(() => Analyze(decodedPath));
    }

    private static SongBeatAnalysis Analyze(string decodedPath)
    {
        var novelty = ReadNovelty(decodedPath);
        var sections = SplitSections(FindOnsets(novelty), novelty.Count);
        var accents = MeasurePeriodicity(sections);
        int best = FindBestPeriod(accents);
        if (accents[best] < 0.12) return NoSuggestion();

        var main = FitCandidate(sections, RefinePeak(accents, best));
        if (main == null) return NoSuggestion();

        var candidates = new List<SongBeatCandidate> { main };
        foreach (double multiple in new[] { 0.5, 2.0 })
        {
            double alternatePeriod = 60.0 * HopsPerSecond / main.Bpm * multiple;
            int lag = (int)Math.Round(alternatePeriod);
            if (lag < MinPeriod || lag > MaxPeriod || accents[lag] < 0.74 * accents[best]) continue;
            var alternate = FitCandidate(sections, alternatePeriod);
            if (alternate != null && Math.Abs(alternate.Bpm / main.Bpm * multiple - 1) <= 0.007)
                candidates.Add(alternate);
        }
        return new SongBeatAnalysis(candidates.ToArray());
    }

    private static SongBeatAnalysis NoSuggestion()
    {
        return new SongBeatAnalysis(new SongBeatCandidate[0]);
    }

    private static List<double> ReadNovelty(string path)
    {
        using (var reader = new WaveFileReader(path))
        {
            var format = reader.WaveFormat;
            if (format.Encoding != WaveFormatEncoding.Pcm || format.SampleRate != BeatSchedule.SampleRate ||
                format.Channels != 2 || format.BitsPerSample != 16)
                throw new InvalidDataException("Beat analysis requires the decoded stereo PCM file.");

            var novelty = new List<double>();
            var bassHistory = new double[5];
            var wideHistory = new double[5];
            var buffer = new byte[HopFrames * format.BlockAlign];
            double lowLeft = 0, lowRight = 0, bassLeft = 0, bassRight = 0;
            // Two low-pass stages emphasize bass drum attacks. Stereo energies are summed.
            const double lowPass = 0.085;
            int bytes;
            while ((bytes = reader.Read(buffer, 0, buffer.Length)) > 0)
            {
                double bassEnergy = 0, wideEnergy = 0;
                for (int i = 0; i < bytes; i += 16)
                {
                    int left = (short)(buffer[i] | buffer[i + 1] << 8);
                    int right = (short)(buffer[i + 2] | buffer[i + 3] << 8);
                    lowLeft += lowPass * (left - lowLeft);
                    lowRight += lowPass * (right - lowRight);
                    bassLeft += lowPass * (lowLeft - bassLeft);
                    bassRight += lowPass * (lowRight - bassRight);
                    bassEnergy += bassLeft * bassLeft + bassRight * bassRight;
                    wideEnergy += (double)left * left + (double)right * right;
                }
                int slot = novelty.Count % bassHistory.Length;
                int taps = (bytes + 15) / 16;
                double bass = Math.Sqrt(bassEnergy / taps);
                double wide = Math.Sqrt(wideEnergy / taps);
                double bassRise = Math.Log((bass + 280) / (bassHistory[slot] + 280));
                double wideRise = Math.Log((wide + 520) / (wideHistory[slot] + 520));
                novelty.Add(0.80 * Math.Max(0, bassRise) + 0.20 * Math.Max(0, wideRise));
                bassHistory[slot] = bass;
                wideHistory[slot] = wide;
            }
            return novelty;
        }
    }

    private struct Onset
    {
        public readonly int Hop;
        public readonly double Weight;

        public Onset(int hop, double weight)
        {
            Hop = hop;
            Weight = weight;
        }
    }

    private static List<Onset> FindOnsets(List<double> novelty)
    {
        var onsets = new List<Onset>();
        const int isolation = 10;
        for (int hop = 0; hop < novelty.Count; hop++)
        {
            double strength = novelty[hop];
            if (strength < 0.18) continue;
            int peak = hop;
            int start = Math.Max(0, hop - isolation);
            int end = Math.Min(novelty.Count - 1, hop + isolation);
            for (int i = start; i <= end; i++)
                if (novelty[i] > novelty[peak]) peak = i;
            if (peak != hop) continue;
            // Walk back to the attack so the grid follows audible starts rather than peaks.
            int attack = hop;
            while (attack > Math.Max(start, hop - 6) && novelty[attack - 1] >= 0.22 * strength)
                attack--;
            onsets.Add(new Onset(attack, Math.Min(2.7, strength)));
            hop = end;
        }
        return onsets;
    }

    private sealed class Section
    {
        public readonly int Start;
        public readonly int Length;
        public readonly List<Onset> Onsets = new List<Onset>();

        public Section(int start, int length)
        {
            Start = start;
            Length = length;
        }
    }

    private static List<Section> SplitSections(List<Onset> onsets, int length)
    {
        int count = Math.Max(1, (int)Math.Round((double)length / SectionHops));
        var sections = new List<Section>();
        int next = 0;
        for (int i = 0; i < count; i++)
        {
            int start = i * length / count;
            int end = (i + 1) * length / count;
            var section = new Section(start, end - start);
            while (next < onsets.Count && onsets[next].Hop < end)
                section.Onsets.Add(onsets[next++]);
            sections.Add(section);
        }
        return sections;
    }

    private static double[] MeasurePeriodicity(IList<Section> sections)
    {
        // Accumulate weighted intervals separately in each section so a loud chorus cannot
        // determine the tempo on its own. Repeated lags help reject isolated subdivisions.
        var intervals = new double[3 * MaxPeriod + 4];
        int contributing = 0;
        foreach (var section in sections)
        {
            var onsets = section.Onsets;
            if (onsets.Count < 8) continue;
            double energy = 0;
            foreach (var onset in onsets) energy += onset.Weight * onset.Weight;
            for (int i = 0; i < onsets.Count; i++)
            {
                for (int j = i + 1; j < onsets.Count; j++)
                {
                    int lag = onsets[j].Hop - onsets[i].Hop;
                    if (lag >= intervals.Length) break;
                    intervals[lag] += onsets[i].Weight * onsets[j].Weight / energy;
                }
            }
            contributing++;
        }

        var scores = new double[MaxPeriod + 1];
        if (contributing == 0) return scores;
        for (int lag = MinPeriod; lag <= MaxPeriod; lag++)
        {
            scores[lag] = (0.58 * SmoothLag(intervals, lag, 4) +
                           0.27 * SmoothLag(intervals, 2 * lag, 5) +
                           0.15 * SmoothLag(intervals, 3 * lag, 6)) / contributing;
        }
        return scores;
    }

    private static int FindBestPeriod(double[] scores)
    {
        int best = MinPeriod;
        for (int period = MinPeriod + 1; period <= MaxPeriod; period++)
            if (scores[period] > scores[best]) best = period;
        return best;
    }

    private static double SmoothLag(double[] intervals, int center, int radius)
    {
        double total = 0;
        for (int i = Math.Max(0, center - radius); i < Math.Min(intervals.Length, center + radius + 1); i++)
        {
            double distance = (i - center) / (double)radius;
            total += intervals[i] * (1 - distance * distance);
        }
        return total;
    }

    private static double RefinePeak(double[] scores, int peak)
    {
        if (peak == MinPeriod || peak == MaxPeriod) return peak;
        double left = scores[peak - 1], center = scores[peak], right = scores[peak + 1];
        double curvature = 2 * center - left - right;
        return curvature > 0 ? peak + 0.5 * (right - left) / curvature : peak;
    }

    private sealed class SectionGrid
    {
        public Section Section;
        public double Anchor;
        public double Period;
        public double Strength;
    }

    private static SongBeatCandidate FitCandidate(List<Section> sections, double period)
    {
        var grids = new SectionGrid[sections.Count];
        var periods = new List<double>();
        for (int i = 0; i < sections.Count; i++)
        {
            var section = sections[i];
            grids[i] = FitSection(section, period, FindSectionPhase(section, period),
                Math.Max(0.18, 2 * PhaseTolerance / period + 0.08));
            if (grids[i] != null) periods.Add(grids[i].Period);
        }
        if (periods.Count == 0) return null;

        periods.Sort();
        period = (periods[(periods.Count - 1) / 2] + periods[periods.Count / 2]) / 2;
        // Coherent sections vote for a shared phase. Local fits keep an edit that shifts the
        // beat from dragging the tempo of the rest of the song.
        double phase = FindSharedPhase(grids, period);
        var fit = new LineFit();
        for (int i = 0; i < grids.Length; i++)
        {
            var grid = grids[i];
            if (grid == null || Math.Abs(PhaseError(grid.Anchor - phase, period)) > PhaseTolerance)
            {
                // A backing accent can outvote the kick in one section. Keep the shared beat
                // if that section still has substantial evidence on the same phase.
                double required = Math.Max(2 * PhaseTolerance / period + 0.035,
                    grid == null ? 0.16 : 0.64 * grid.Strength);
                var shared = FitSection(sections[i], period, phase, required);
                if (shared != null && Math.Abs(PhaseError(shared.Anchor - phase, period)) <= PhaseTolerance)
                    grids[i] = grid = shared;
            }
            if (grid != null && Math.Abs(PhaseError(grid.Anchor - phase, period)) <= PhaseTolerance)
                fit.Add(Math.Round((grid.Anchor - phase) / period), grid.Anchor - phase, grid.Strength);
        }
        double refined = fit.Slope(period);
        if (Math.Abs(refined - period) < 0.003 * period)
        {
            phase += fit.Intercept(refined);
            period = refined;
        }

        int aligned = 0, mismatched = 0;
        int? firstMismatch = null;
        SectionGrid previousMismatch = null;
        int drum = -1;
        foreach (var grid in grids)
        {
            if (grid == null)
            {
                previousMismatch = null;
                continue;
            }
            if (Math.Abs(PhaseError(grid.Anchor - phase, period)) <= PhaseTolerance)
            {
                aligned++;
                if (drum < 0) drum = FindDrum(grid.Section, phase, period);
                previousMismatch = null;
            }
            else
            {
                mismatched++;
                if (previousMismatch != null && !firstMismatch.HasValue &&
                    Math.Abs(PhaseError(grid.Anchor - previousMismatch.Anchor, period)) <= PhaseTolerance)
                {
                    int displacedBeat = FindDrum(grid.Section, grid.Anchor, grid.Period);
                    if (displacedBeat >= 0) firstMismatch = displacedBeat * HopFrames;
                }
                previousMismatch = grid;
            }
        }
        if (drum < 0) return null;
        bool uncertain = mismatched > 0 || aligned <= sections.Count / 2 ||
            HasShortDisagreement(sections, grids, phase, period);
        return new SongBeatCandidate(Math.Round(60 * HopsPerSecond / period, 4), drum * HopFrames,
            uncertain, aligned > mismatched ? firstMismatch : null);
    }

    private static bool HasShortDisagreement(List<Section> sections, SectionGrid[] grids, double phase, double period)
    {
        double uniform = 2 * PhaseTolerance / period;
        for (int i = 0; i < sections.Count; i++)
        {
            var section = sections[i];
            if (grids[i] == null)
            {
                // A weak passage can borrow the grid. A strong independent tempo cannot.
                var scores = MeasurePeriodicity(new[] { section });
                double best = scores[FindBestPeriod(scores)];
                int expected = Math.Max(MinPeriod, Math.Min(MaxPeriod, (int)Math.Round(period)));
                if (best >= 0.35 && scores[expected] < 0.60 * best) return true;
            }

            // A cut close to the beginning, end or middle of a fitted section can leave
            // too few displaced beats to change that section's winning grid.
            int middle = section.Start + section.Length / 2;
            var first = new Section(section.Start, middle - section.Start);
            var second = new Section(middle, section.Start + section.Length - middle);
            foreach (var onset in section.Onsets)
                (onset.Hop < middle ? first : second).Onsets.Add(onset);
            foreach (var half in new[] { first, second })
            {
                var local = FitSection(half, period, FindSectionPhase(half, period), Math.Max(0.30, uniform + 0.10));
                if (local == null || Math.Abs(PhaseError(local.Anchor - phase, period)) <= PhaseTolerance) continue;
                var shared = FitSection(half, period, phase, Math.Max(uniform + 0.012, 0.50 * local.Strength));
                if (shared == null || Math.Abs(PhaseError(shared.Anchor - phase, period)) > PhaseTolerance)
                    return true;
            }
        }
        return false;
    }

    private static SectionGrid FitSection(Section section, double period, double phase, double minimumStrength)
    {
        if (section.Onsets.Count < 5) return null;
        double center = section.Start + section.Length / 2.0;
        double anchor = center - PhaseError(center - phase, period);
        var fit = new LineFit();
        var beats = new HashSet<int>();
        double total = 0;
        foreach (var onset in section.Onsets)
        {
            total += onset.Weight;
            double offset = onset.Hop - anchor;
            int beat = (int)Math.Round(offset / period);
            if (Math.Abs(offset - beat * period) <= PhaseTolerance)
            {
                fit.Add(beat, offset, onset.Weight);
                beats.Add(beat);
            }
        }
        if (beats.Count < 5 || fit.Weight < total * minimumStrength) return null;
        double refined = fit.Slope(period);
        if (Math.Abs(refined - period) > 0.015 * period) return null;
        return new SectionGrid {
            Section = section, Anchor = anchor + fit.Intercept(refined), Period = refined,
            Strength = fit.Weight / total
        };
    }

    private static double FindSectionPhase(Section section, double period)
    {
        var bins = new double[(int)Math.Round(period)];
        foreach (var onset in section.Onsets)
            AddPhaseVote(bins, onset.Hop - section.Start, period, onset.Weight);
        return section.Start + StrongestPhase(bins, period);
    }

    private static double FindSharedPhase(SectionGrid[] grids, double period)
    {
        var bins = new double[(int)Math.Round(period)];
        foreach (var grid in grids)
            if (grid != null) AddPhaseVote(bins, grid.Anchor, period, grid.Strength);
        return StrongestPhase(bins, period);
    }

    private static void AddPhaseVote(double[] bins, double hop, double period, double weight)
    {
        int center = (int)Math.Round((hop % period + period) % period * bins.Length / period) % bins.Length;
        const int radius = PhaseTolerance - 1;
        for (int i = -radius; i <= radius; i++)
            bins[(center + i + bins.Length) % bins.Length] += weight * (1 - Math.Abs(i) / (radius + 1.0));
    }

    private static double StrongestPhase(double[] bins, double period)
    {
        int best = 0;
        for (int i = 1; i < bins.Length; i++)
            if (bins[i] > bins[best]) best = i;
        return best * period / bins.Length;
    }

    private static double PhaseError(double offset, double period)
    {
        return offset - Math.Round(offset / period) * period;
    }

    private static int FindDrum(Section section, double phase, double period)
    {
        var matched = new List<Onset>();
        double weight = 0;
        foreach (var onset in section.Onsets)
        {
            if (Math.Abs(PhaseError(onset.Hop - phase, period)) <= PhaseTolerance)
            {
                matched.Add(onset);
                weight += onset.Weight;
            }
        }
        for (int i = 0; i + 2 < matched.Count; i++)
        {
            var onset = matched[i];
            double adjustment = PhaseError(onset.Hop - phase, period);
            int gridHop = (int)Math.Round(onset.Hop - adjustment);
            // Leave room to hear the attack coming, and skip the file's opening transient.
            if (onset.Weight < 0.75 * weight / matched.Count ||
                gridHop < Math.Max(section.Start, HopsPerSecond / 4) || gridHop >= section.Start + section.Length) continue;
            int nearbyBeats = 0, previousBeat = 0;
            for (int j = i + 1; j < matched.Count; j++)
            {
                int beat = (int)Math.Round((matched[j].Hop - gridHop) / period);
                if (beat > 4) break;
                if (beat != previousBeat && ++nearbyBeats == 2) return gridHop;
                previousBeat = beat;
            }
        }
        return -1;
    }

    private struct LineFit
    {
        public double Weight;
        private double x, y, xx, xy;

        public void Add(double index, double time, double weight)
        {
            Weight += weight;
            x += index * weight;
            y += time * weight;
            xx += index * index * weight;
            xy += index * time * weight;
        }

        public double Slope(double fallback)
        {
            double variance = Weight * xx - x * x;
            return variance > 0.001 ? (Weight * xy - x * y) / variance : fallback;
        }

        public double Intercept(double slope)
        {
            return Weight > 0 ? (y - slope * x) / Weight : 0;
        }
    }
}
