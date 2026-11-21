using System;
using System.Collections.Generic;

public abstract class ShipMotion
{
    public double PeakTime { get; protected set; }
    public abstract bool CanPlay { get; }
    public abstract double ProgressAt(double time);
    public abstract double ProgressRate(double time, bool outgoing);
    public abstract double[] ExportTimes(int intervals, double period);
}

// Handle speeds are the cubic Bezier ordinates at 1/3 and 2/3 of a segment.
public sealed class BounceKey
{
    public double Time { get; set; }
    public double Speed { get; set; }
    public bool Smooth { get; set; }
    public bool HasSavedHandles { get; set; }
    public double InSpeed { get; set; }
    public double OutSpeed { get; set; }

    public BounceKey Copy() { return (BounceKey)MemberwiseClone(); }
}

public sealed class BeatCurve : ShipMotion
{
    readonly BounceKey[] keys;
    readonly double[] area;
    public BounceKey[] Keys { get { return Array.ConvertAll(keys, p => p.Copy()); } }
    public override bool CanPlay { get { return area[area.Length - 1] > 0; } }
    public bool IsUniform { get { return keys.Length == 2 && !keys[0].Smooth && keys[0].Speed == keys[1].Speed && CanPlay; } }

    public static BeatCurve Uniform()
    {
        return new BeatCurve(new[] { new BounceKey { Speed = 1 }, new BounceKey { Time = 1, Speed = 1 } });
    }

    public BeatCurve(BounceKey[] points)
    {
        if (points == null || points.Length < 2 || points[0].Time != 0 || points[points.Length - 1].Time != 1)
            throw new ArgumentException("曲线须从拍头连到拍尾。");
        keys = Array.ConvertAll(points, p => p.Copy());
        area = new double[keys.Length];
        for (int i = 0; i < keys.Length; i++)
        {
            BounceKey p = keys[i];
            if (!Nonnegative(p.Time) || !Nonnegative(p.Speed) || !Nonnegative(p.InSpeed) || !Nonnegative(p.OutSpeed))
                throw new ArgumentException("时间和相对播放速度须为有限非负数。");
            if (i == 0) continue;
            if (p.Time <= keys[i - 1].Time) throw new ArgumentException("关键点时间须递增。");
            double speed;
            area[i] = area[i - 1] + Segment(i - 1, 1, out speed);
        }
        if (CanPlay) PeakTime = TimeAtPhase(0.5);
    }

    static bool Nonnegative(double x) { return x >= 0 && x <= float.MaxValue; }
    static double Mix(double a, double b, double t) { return a * (1 - t) + b * t; }

    // The prefix of a cubic is itself a Bezier. Its integral equals its duration
    // times the average of its four control ordinates (de Casteljau subdivision).
    double Segment(int i, double u, out double speed)
    {
        BounceKey a = keys[i], b = keys[i + 1];
        double duration = (b.Time - a.Time) * u;
        if (!a.Smooth)
        {
            speed = Mix(a.Speed, b.Speed, u);
            return duration * (a.Speed + speed) / 2;
        }
        double q = Mix(a.Speed, a.OutSpeed, u);
        double middle = Mix(a.OutSpeed, b.InSpeed, u);
        double r = Mix(q, middle, u);
        speed = Mix(r, Mix(middle, Mix(b.InSpeed, b.Speed, u), u), u);
        return duration * (a.Speed + q + r + speed) / 4;
    }

    double Sample(double time, out double speed)
    {
        time = Math.Max(0, Math.Min(1, time));
        int lo = 0, hi = keys.Length - 1;
        while (hi - lo > 1)
        {
            int mid = lo + (hi - lo) / 2;
            if (keys[mid].Time <= time) lo = mid; else hi = mid;
        }
        double u = (time - keys[lo].Time) / (keys[lo + 1].Time - keys[lo].Time);
        return area[lo] + Segment(lo, u, out speed);
    }

    public double SpeedAt(double time) { double speed; Sample(time, out speed); return speed; }
    public double Phase(double time) { double speed; return CanPlay ? Sample(time, out speed) / area[area.Length - 1] : 0; }
    public double PhaseRate(double time) { return SpeedAt(time) / area[area.Length - 1]; }

    public override double ProgressAt(double time)
    {
        return (1 - Math.Cos(2 * Math.PI * Phase(time))) / 2;
    }

    public override double ProgressRate(double time, bool outgoing)
    {
        double phase = Phase(time);
        if (Math.Abs(phase * 2 - Math.Round(phase * 2)) < 1e-14) return 0;
        return Math.PI * Math.Sin(2 * Math.PI * phase) * PhaseRate(time);
    }

    double TimeAtPhase(double phase)
    {
        double lo = 0, hi = 1;
        for (int i = 0; i < 54; i++)
        {
            double mid = (lo + hi) / 2;
            if (Phase(mid) < phase) lo = mid; else hi = mid;
        }
        return (lo + hi) / 2;
    }

    public override double[] ExportTimes(int intervals, double period)
    {
        if (!CanPlay) throw new InvalidOperationException("整拍速度都为零。请提高至少一段速度，再应用。");
        var times = new SortedSet<double>();
        for (int i = 0; i <= intervals; i++) times.Add((double)i / intervals);
        if (IsUniform)
            return new List<double>(times).ToArray();

        // Bound both elapsed time and traversed phase between samples. Include
        // segment boundaries even when a short hold is between two regular frames.
        for (int i = 0; i < keys.Length; i++)
        {
            times.Add(keys[i].Time);
            if (i > 0)
                for (int j = 1; j < 4; j++) times.Add(Mix(keys[i-1].Time, keys[i].Time, j / 4.0));
        }
        for (int i = 1; i < intervals; i++) times.Add(TimeAtPhase((double)i / intervals));
        var result = new List<double>();
        foreach (double time in times)
        {
            // Game frame times are single precision seconds.
            if (result.Count == 0 || (float)(result[result.Count - 1] * period) != (float)(time * period))
                result.Add(time);
            else if (time == 1) result[result.Count - 1] = 1;
        }
        return result.ToArray();
    }
}
