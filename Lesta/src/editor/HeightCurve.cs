using System;
using System.Collections.Generic;

public enum HeightSegment { Linear, Smooth, Cosine }

public sealed class HeightKey
{
    public double Time { get; set; }
    public double Pose { get; set; }
    public double InPose { get; set; }
    public double OutPose { get; set; }
    public HeightSegment Segment { get; set; }
    public HeightSegment PreviousSmooth { get; set; }
    public double CosineStart { get; set; }
    public double CosineEnd { get; set; }

    public HeightKey Copy() { return (HeightKey)MemberwiseClone(); }
}

public sealed class HeightCurve : ShipMotion
{
    readonly HeightKey[] keys;
    public HeightKey[] Keys { get { return Array.ConvertAll(keys, p => p.Copy()); } }
    public override bool CanPlay { get { return true; } }

    public static HeightCurve Default() { return WithPeak(HeightSegment.Cosine); }
    public static HeightCurve Triangle() { return WithPeak(HeightSegment.Linear); }

    public bool HasSimpleTiming
    {
        get { return (keys.Length == 3 || (keys.Length == 4 && keys[1].Pose == 0)) &&
                     keys[keys.Length - 2].Pose == 1; }
    }

    public double HoldEnd { get { return HasSimpleTiming && keys.Length == 4 ? keys[1].Time : 0; } }

    public HeightCurve WithTiming(double hold, double peak)
    {
        if (!HasSimpleTiming) throw new InvalidOperationException("请先选择套用简单动作。");
        if (!(0 <= hold && hold < peak && peak < 1)) throw new ArgumentException("起弹须早于峰值，峰值须在下一拍前。");
        if (hold == HoldEnd && peak == PeakTime) return this;
        var points = new List<HeightKey>(Keys);
        if (hold > 0 && points.Count == 3) points.Insert(0, new HeightKey());
        if (hold == 0 && points.Count == 4) points.RemoveAt(0);
        points[points.Count - 3].Time = hold;
        points[points.Count - 2].Time = peak;
        return new HeightCurve(points.ToArray());
    }

    static HeightCurve WithPeak(HeightSegment segment)
    {
        return new HeightCurve(new[] {
            new HeightKey { Segment = segment, CosineEnd = 1 },
            new HeightKey { Time = 0.5, Pose = 1, Segment = segment, CosineEnd = 1 },
            new HeightKey { Time = 1 }
        });
    }

    public HeightCurve(HeightKey[] points)
    {
        if (points == null || points.Length < 2 || points[0].Time != 0 ||
            points[points.Length - 1].Time != 1 || points[0].Pose != 0 || points[points.Length - 1].Pose != 0)
            throw new ArgumentException("动画曲线须以最扁姿态开始和结束。");
        keys = Array.ConvertAll(points, p => p.Copy());
        double peak = 0;
        for (int i = 0; i < keys.Length; i++)
        {
            HeightKey a = keys[i];
            if (!Unit(a.Time) || !Unit(a.Pose) || (i > 0 && a.Time <= keys[i - 1].Time))
                throw new ArgumentException("船形关键点须在范围内，时间须递增。");
            if (a.Pose > peak) { peak = a.Pose; PeakTime = a.Time; }
            if (i + 1 == keys.Length) continue;
            HeightKey b = keys[i + 1];
            switch (a.Segment)
            {
                case HeightSegment.Linear: break;
                case HeightSegment.Smooth:
                    if (!Unit(a.OutPose) || !Unit(b.InPose))
                        throw new ArgumentException("平滑段的控制点须在姿态范围内。");
                    break;
                case HeightSegment.Cosine:
                    if (!Unit(a.CosineStart) || !Unit(a.CosineEnd) || a.CosineStart >= a.CosineEnd)
                        throw new ArgumentException("默认平滑段的范围无效。");
                    break;
                default: throw new ArgumentException("未知的船形插值方式。");
            }
        }
    }

    static bool Unit(double x) { return x >= 0 && x <= 1; }
    static double Mix(double a, double b, double u) { return a + (b - a) * u; }
    internal static double ClampBetween(double x, double a, double b)
    {
        return Math.Max(Math.Min(a, b), Math.Min(Math.Max(a, b), x));
    }

    int SegmentAt(double time, bool outgoing)
    {
        int lo = 0, hi = keys.Length - 1;
        while (hi - lo > 1)
        {
            int mid = (lo + hi) / 2;
            if (keys[mid].Time < time || (outgoing && keys[mid].Time == time)) lo = mid; else hi = mid;
        }
        return lo;
    }

    double Sample(double time, bool outgoing, out double rate)
    {
        time = ClampBetween(time, 0, 1);
        int i = SegmentAt(time, outgoing);
        HeightKey a = keys[i], b = keys[i + 1];
        double span = b.Time - a.Time, u = (time - a.Time) / span;
        double delta = b.Pose - a.Pose;
        if (delta == 0) { rate = 0; return a.Pose; }
        if (a.Segment == HeightSegment.Cosine)
        {
            double start = a.CosineStart, end = a.CosineEnd, x = Mix(start, end, u);
            // cos(pi*a) - cos(pi*b), evaluated without cancellation near the ends.
            double difference = 2 * Math.Sin(Math.PI * (start + end) / 2) * Math.Sin(Math.PI * (end - start) / 2);
            double rise = 2 * Math.Sin(Math.PI * (start + x) / 2) * Math.Sin(Math.PI * (x - start) / 2);
            rate = x == 0 || x == 1 ? 0 : delta * Math.PI * Math.Sin(Math.PI * x) * (end - start) / (difference * span);
            return Mix(a.Pose, b.Pose, rise / difference);
        }
        if (a.Segment == HeightSegment.Smooth)
        {
            double q = Mix(a.Pose, a.OutPose, u), m = Mix(a.OutPose, b.InPose, u), s = Mix(b.InPose, b.Pose, u);
            double r = Mix(q, m, u), t = Mix(m, s, u);
            rate = 3 * (t - r) / span;
            return Mix(r, t, u);
        }
        rate = delta / span;
        return Mix(a.Pose, b.Pose, u);
    }

    public override double ProgressAt(double time)
    {
        double rate;
        return Sample(time, true, out rate);
    }

    public override double ProgressRate(double time, bool outgoing)
    {
        double rate;
        Sample(time, outgoing, out rate);
        return rate;
    }

    public override double[] ExportTimes(int intervals, double period)
    {
        // Game times are single precision. Keep authored boundaries ahead of regular samples.
        var times = new SortedDictionary<float, double>();
        for (int i = 0; i <= intervals; i++)
        {
            double t = (double)i / intervals;
            times[(float)(t * period)] = t;
        }
        for (int i = 0; i + 1 < keys.Length; i++)
        {
            HeightKey a = keys[i], b = keys[i + 1];
            // Cubic and linear spans are exact with their endpoint tangents.
            // Short cosine spans need interior samples even between regular frames.
            const int cosineSamples = 8;
            if (a.Segment != HeightSegment.Cosine || a.Pose == b.Pose ||
                b.Time - a.Time >= (double)cosineSamples / intervals) continue;
            for (int j = 1; j < cosineSamples; j++)
            {
                double t = Mix(a.Time, b.Time, (double)j / cosineSamples);
                times[(float)(t * period)] = t;
            }
        }
        foreach (HeightKey key in keys) times[(float)(key.Time * period)] = key.Time;
        times[(float)(PeakTime * period)] = PeakTime;
        times[0] = 0;
        times[(float)period] = 1;
        return new List<double>(times.Values).ToArray();
    }

    public HeightCurve Split(double time)
    {
        if (time <= 0 || time >= 1) return this;
        var points = new List<HeightKey>(Keys);
        int i = SegmentAt(time, true);
        HeightKey a = points[i], b = points[i + 1];
        if (time == a.Time) return this;
        double u = (time - a.Time) / (b.Time - a.Time);
        var point = new HeightKey { Time = time, Pose = ProgressAt(time), Segment = a.Segment };
        // Two newly divided straight spans each start with their own easing.
        if (a.Segment == HeightSegment.Linear) a.PreviousSmooth = HeightSegment.Linear;
        if (a.Segment == HeightSegment.Smooth)
        {
            double q = Mix(a.Pose, a.OutPose, u), m = Mix(a.OutPose, b.InPose, u), s = Mix(b.InPose, b.Pose, u);
            point.InPose = Mix(q, m, u);
            point.OutPose = Mix(m, s, u);
            a.OutPose = q;
            b.InPose = s;
        }
        if (a.Segment == HeightSegment.Cosine)
        {
            point.CosineStart = Mix(a.CosineStart, a.CosineEnd, u);
            point.CosineEnd = a.CosineEnd;
            if (point.CosineStart == a.CosineStart || point.CosineStart == a.CosineEnd) return this;
            a.CosineEnd = point.CosineStart;
        }
        points.Insert(i + 1, point);
        return new HeightCurve(points.ToArray());
    }

    internal static void BoundHandles(HeightKey a, HeightKey b)
    {
        a.OutPose = ClampBetween(a.OutPose, a.Pose, b.Pose);
        b.InPose = ClampBetween(b.InPose, a.Pose, b.Pose);
    }

    public HeightCurve MirrorFirstHalf()
    {
        var half = new List<HeightKey>(Array.FindAll(Split(0.5).Keys, p => p.Time <= 0.5));
        for (int i = half.Count - 2; i >= 0; i--)
        {
            HeightKey a = half[i], b = half[i + 1], c = half[half.Count - 1];
            double time = 1 - a.Time;
            // Values too close to 0 or .5 can share a reflected double.
            if (time <= c.Time || (time == 1 && i > 0)) continue;
            c.Segment = a.Segment;
            c.PreviousSmooth = a.PreviousSmooth;
            c.CosineStart = 1 - a.CosineEnd;
            c.CosineEnd = 1 - a.CosineStart;
            if (c.Segment == HeightSegment.Cosine && c.CosineStart == c.CosineEnd)
                c.Segment = HeightSegment.Linear;
            if (c.PreviousSmooth == HeightSegment.Cosine && c.CosineStart == c.CosineEnd)
                c.PreviousSmooth = HeightSegment.Linear;
            c.OutPose = b.InPose;
            half.Add(new HeightKey { Time = time, Pose = a.Pose, InPose = a.OutPose });
        }
        return new HeightCurve(half.ToArray());
    }

    public static HeightCurve FromSpeedCurve(BeatCurve source)
    {
        if (source.IsUniform) return Default();
        var times = new SortedSet<double> { source.PeakTime };
        foreach (BounceKey key in source.Keys) times.Add(key.Time);
        var points = new List<HeightKey>();
        foreach (double time in times)
        {
            var key = new HeightKey { Time = time, Pose = source.ProgressAt(time) };
            if (points.Count == 0) points.Add(key);
            else FitLegacySegment(source, points, key, 0);
        }
        return new HeightCurve(points.ToArray());
    }

    static void FitLegacySegment(BeatCurve source, List<HeightKey> points, HeightKey b, int depth)
    {
        HeightKey a = points[points.Count - 1];
        double span = b.Time - a.Time;
        a.Segment = HeightSegment.Smooth;
        a.OutPose = a.Pose + source.ProgressRate(a.Time, true) * span / 3;
        b.InPose = b.Pose - source.ProgressRate(b.Time, false) * span / 3;
        BoundHandles(a, b);
        // Only an explicit conversion approximates the old motion. Include its
        // original boundaries and peak, then subdivide until the fit is close.
        if (depth < 12)
        {
            for (int i = 1; i < 8; i++)
            {
                double u = i / 8.0, v = 1 - u, time = Mix(a.Time, b.Time, u);
                double fitted = v * v * v * a.Pose + 3 * v * v * u * a.OutPose +
                    3 * v * u * u * b.InPose + u * u * u * b.Pose;
                if (Math.Abs(fitted - source.ProgressAt(time)) < 0.0002) continue;
                double middle = Mix(a.Time, b.Time, 0.5);
                if (middle == a.Time || middle == b.Time) break;
                FitLegacySegment(source, points, new HeightKey { Time = middle, Pose = source.ProgressAt(middle) }, depth + 1);
                FitLegacySegment(source, points, b, depth + 1);
                return;
            }
        }
        points.Add(b);
    }
}
