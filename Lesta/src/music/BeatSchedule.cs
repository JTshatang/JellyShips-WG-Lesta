using System;

public sealed class BeatSchedule
{
    public const int SampleRate = 48000;
    internal double FramesPerBeat { get; private set; }
    public int DrumFrame { get; private set; }
    public double Period { get { return FramesPerBeat / SampleRate; } }

    public BeatSchedule(double bpm, int drumFrame)
    {
        if (!IsValidBpm(bpm) || drumFrame < 0)
            throw new ArgumentException("Invalid song tempo or drum reference.");
        FramesPerBeat = SampleRate * 60.0 / bpm;
        DrumFrame = drumFrame;
    }

    public static bool IsValidBpm(double bpm)
    {
        return bpm >= 1 && bpm <= 600;
    }

    public long StartFrame(double referenceBeatFrame, double animationPeriod, long earliest)
    {
        double cycleFrames = animationPeriod * SampleRate;
        double beats = cycleFrames / FramesPerBeat;
        double nearest = Math.Round(beats);
        // A measured song BPM can be slightly off an integer ratio. Follow the animation
        // cycle for that ratio so the preview keeps its pose when it repeats.
        double period = nearest >= 1 && Math.Abs(beats - nearest) <= 0.00025 * nearest
            ? cycleFrames : FramesPerBeat;
        return NextFrame(referenceBeatFrame - DrumFrame, period, earliest);
    }

    public long ResumeFrame(double reference, double animationPeriod, long earliest)
    {
        return NextFrame(reference, animationPeriod * SampleRate, earliest);
    }

    private static long NextFrame(double reference, double period, long earliest)
    {
        double cycles = Math.Max(0, Math.Ceiling((earliest - reference) / period));
        return (long)Math.Round(reference + cycles * period);
    }

    public long AfterRepeatSilence(long endFrame)
    {
        return endFrame + (long)Math.Ceiling(FramesPerBeat);
    }

    public long PreviewRepeatFrame(long duration, double animationPeriod)
    {
        return StartFrame(DrumFrame, animationPeriod, AfterRepeatSilence(duration));
    }

    public static double AnimationPosition(long songFrame, long drumFrame, double animationBpm)
    {
        double cycles = (songFrame - drumFrame) * animationBpm / (60.0 * SampleRate);
        return cycles - Math.Floor(cycles);
    }

    public double PositionAt(long songFrame)
    {
        double cycles = (songFrame - DrumFrame) / FramesPerBeat;
        return cycles - Math.Floor(cycles);
    }
}
