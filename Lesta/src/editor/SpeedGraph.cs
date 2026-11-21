using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public sealed class SpeedGraph : Control
{
    readonly List<BounceKey> keys = new List<BounceKey>();
    int selected;
    enum Drag { None, Point, OutHandle, InHandle, Cursor }
    Drag drag;
    double position, ceiling = 4;
    public BeatCurve Curve { get; private set; }
    public event EventHandler CurveEdited, CursorMoved, SelectionChanged;

    public SpeedGraph()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = Color.White;
        ForeColor = Color.FromArgb(54, 93, 112);
        AccessibleName = "相对播放速度曲线";
        SetCurve(BeatCurve.Uniform());
    }

    public void SetCurve(BeatCurve curve)
    {
        keys.Clear();
        keys.AddRange(curve.Keys);
        selected = 0;
        ceiling = 4;
        foreach (BounceKey p in keys)
            ceiling = Math.Max(ceiling, Math.Max(p.Speed, Math.Max(p.InSpeed, p.OutSpeed)));
        Edited();
        SelectKey(0);
    }
    public double Position
    {
        get { return position; }
        set { position = Clamp(value, 0, 1); Invalidate(); }
    }

    int Segment { get { return Math.Min(selected, keys.Count - 2); } }
    public bool Smooth { get { return keys[Segment].Smooth; } }
    public bool CanDelete { get { return selected > 0 && selected < keys.Count - 1; } }

    public void SetSmooth(bool smooth)
    {
        if (Smooth == smooth) return;
        BounceKey a = keys[Segment], b = keys[Segment + 1];
        a.Smooth = smooth;
        if (smooth && !a.HasSavedHandles)
        {
            a.OutSpeed = a.Speed;
            b.InSpeed = b.Speed;
        }
        a.HasSavedHandles = !smooth;
        Edited();
    }

    public void SelectAdjacentKey(int direction)
    {
        if (keys.Count == 0) return;
        SelectKey(Math.Max(0, Math.Min(selected + direction, keys.Count - 1)));
        Seek(keys[selected].Time);
    }

    public void DeleteSelected()
    {
        if (!CanDelete) return;
        keys.RemoveAt(selected);
        SelectKey(selected - 1);
        Edited();
    }

    void SelectKey(int index)
    {
        selected = index;
        if (SelectionChanged != null) SelectionChanged(this, EventArgs.Empty);
        Invalidate();
    }

    void Edited()
    {
        Curve = new BeatCurve(keys.ToArray());
        if (CurveEdited != null) CurveEdited(this, EventArgs.Empty);
        Invalidate();
    }

    float ScaleUnit { get { return Font.Height / 19f; } }
    RectangleF Plot
    {
        get
        {
            float left = 34 * ScaleUnit, top = 30 * ScaleUnit;
            return new RectangleF(left, top, Math.Max(1, Width - left - 16 * ScaleUnit),
                                  Math.Max(1, Height - top - 42 * ScaleUnit));
        }
    }
    static double Clamp(double v, double low, double high) { return Math.Max(low, Math.Min(high, v)); }
    static double Mix(double a, double b, double u) { return a * (1-u) + b*u; }
    PointF Pixel(double time, double speed)
    {
        RectangleF r = Plot;
        return new PointF(r.Left + (float)(time * r.Width), r.Bottom - (float)(speed / ceiling * r.Height));
    }
    PointF KeyPixel(int index) { return Pixel(keys[index].Time, keys[index].Speed); }
    PointF HandlePixel(int index, bool outgoing)
    {
        BounceKey a = keys[index], b = keys[index + 1];
        return Pixel(Mix(a.Time, b.Time, outgoing ? 1.0/3 : 2.0/3), outgoing ? a.OutSpeed : b.InSpeed);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
        Graphics g = e.Graphics;
        RectangleF r = Plot;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.DrawString("相对播放速度", Font, Brushes.DarkSlateGray, r.Left, 0);
        for (int i = 0; i <= 4; i++)
        {
            double fraction = i / 4.0;
            PointF axis = Pixel(fraction, ceiling * fraction);
            g.DrawLine(Pens.Gainsboro, r.Left, axis.Y, r.Right, axis.Y);
            g.DrawLine(Pens.Gainsboro, axis.X, r.Top, axis.X, r.Bottom);
            g.DrawString((ceiling * fraction).ToString("0.#"), Font, Brushes.DimGray, 2, axis.Y - Font.Height/2);
            g.DrawString((25*i).ToString() + "%", Font, Brushes.DimGray,
                         Math.Min(Width - 40 * ScaleUnit, axis.X - 8 * ScaleUnit), r.Bottom + 2);
        }
        g.DrawString("一拍内的时间", Font, Brushes.DarkSlateGray, r.Left, Height - Font.Height);
        using (Pen line = new Pen(Color.Gray, 2.5f * ScaleUnit))
        {
            for (int i = 0; i < keys.Count - 1; i++)
            {
                line.Color = i == Segment ? ForeColor : Color.Gray;
                line.Width = (i == Segment ? 3.5f : 1.6f) * ScaleUnit;
                if (keys[i].Smooth)
                    g.DrawBezier(line, KeyPixel(i), HandlePixel(i, true), HandlePixel(i, false), KeyPixel(i+1));
                else g.DrawLine(line, KeyPixel(i), KeyPixel(i+1));
            }
        }
        float x = Pixel(position, 0).X;
        g.DrawLine(Pens.Black, x, r.Top, x, r.Bottom + 6 * ScaleUnit);
        if (Smooth)
        {
            foreach (bool outgoing in new[] { true, false })
            {
                PointF h = HandlePixel(Segment, outgoing);
                g.DrawLine(Pens.SlateGray, KeyPixel(outgoing ? Segment : Segment+1), h);
                float size = 4 * ScaleUnit;
                g.FillRectangle(Brushes.SlateGray, h.X-size, h.Y-size, size*2, size*2);
            }
        }
        for (int i = 0; i < keys.Count; i++)
        {
            PointF p = KeyPixel(i);
            float radius = (selected == i ? 6 : 4) * ScaleUnit;
            g.FillEllipse(i == selected ? Brushes.DarkSlateGray : Brushes.Gray,
                          p.X-radius, p.Y-radius, 2*radius, 2*radius);
        }
    }

    static double DistanceSquared(PointF p, MouseEventArgs e)
    {
        double dx = p.X - e.X, dy = p.Y - e.Y;
        return dx * dx + dy * dy;
    }

    bool GrabControl(MouseEventArgs e)
    {
        double closest = Math.Pow(8 * ScaleUnit, 2);
        int key = -1;
        for (int i = 0; i < keys.Count; i++)
        {
            double distance = DistanceSquared(KeyPixel(i), e);
            if (distance >= closest) continue;
            closest = distance;
            key = i;
            drag = Drag.Point;
        }
        if (Smooth)
        {
            foreach (bool outgoing in new[] { true, false })
            {
                double distance = DistanceSquared(HandlePixel(Segment, outgoing), e);
                if (distance >= closest) continue;
                closest = distance;
                drag = outgoing ? Drag.OutHandle : Drag.InHandle;
            }
        }
        if (drag == Drag.Point)
        {
            SelectKey(key);
            Seek(keys[key].Time);
        }
        return drag != Drag.None;
    }

    double TimeAt(int x) { return Clamp((x - Plot.Left) / Plot.Width, 0, 1); }
    double SpeedAt(int y) { return ceiling * Clamp((Plot.Bottom - y) / Plot.Height, 0, 1); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();
        drag = Drag.None;
        if (GrabControl(e))
        {
            Capture = true;
            return;
        }
        RectangleF plot = Plot;
        double t = TimeAt(e.X);
        double lineSpeed = Curve.SpeedAt(t);
        bool onCurve = e.X >= plot.Left && e.X <= plot.Right &&
                       Math.Abs(e.Y - Pixel(t, lineSpeed).Y) <= 3 * ScaleUnit;
        if (!onCurve && (e.Y >= plot.Bottom || Math.Abs(e.X - Pixel(position, 0).X) < 4 * ScaleUnit))
        {
            drag = Drag.Cursor;
            Seek(t);
        }
        else if (onCurve || plot.Contains(e.Location))
        {
            int index = keys.FindIndex(k => k.Time >= t);
            if (index <= 0 || keys[index].Time == t) return;
            BounceKey a = keys[index-1], b = keys[index];
            double u = (t - a.Time) / (b.Time - a.Time);
            var point = new BounceKey { Time = t, Speed = onCurve ? lineSpeed : SpeedAt(e.Y), Smooth = a.Smooth };
            a.HasSavedHandles = false;
            if (a.Smooth)
            {
                // Subdivide the selected cubic so inserting on the line preserves its shape.
                double q = Mix(a.Speed, a.OutSpeed, u), m = Mix(a.OutSpeed, b.InSpeed, u);
                double s = Mix(b.InSpeed, b.Speed, u);
                point.InSpeed = Mix(q, m, u);
                point.OutSpeed = Mix(m, s, u);
                a.OutSpeed = q;
                b.InSpeed = s;
            }
            keys.Insert(index, point);
            SelectKey(index);
            Position = t;
            drag = Drag.Point;
            Edited();
        }
        Capture = drag != Drag.None;
    }

    void Seek(double time)
    {
        Position = time;
        if (CursorMoved != null) CursorMoved(this, EventArgs.Empty);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (drag == Drag.None) return;
        if (drag == Drag.Cursor) { Seek(TimeAt(e.X)); return; }
        double v = SpeedAt(e.Y);
        if (drag == Drag.OutHandle) keys[Segment].OutSpeed = v;
        else if (drag == Drag.InHandle) keys[Segment+1].InSpeed = v;
        else
        {
            keys[selected].Speed = v;
            double t = TimeAt(e.X);
            if (CanDelete && t > keys[selected-1].Time && t < keys[selected+1].Time)
                keys[selected].Time = t;
        }
        if (drag == Drag.Point) Position = keys[selected].Time;
        else Position = Mix(keys[Segment].Time, keys[Segment+1].Time, drag == Drag.OutHandle ? 1.0/3 : 2.0/3);
        Edited();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        drag = Drag.None;
        Capture = false;
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (!Capture) drag = Drag.None;
    }
}
