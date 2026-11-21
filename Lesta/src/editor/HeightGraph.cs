using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public sealed class HeightGraph : Control
{
    enum Drag { None, Cursor, Point, OutHandle, InHandle }
    Drag drag;
    HeightKey[] keys = new HeightKey[0];
    int selected;
    double position, flatHeight = 80, tallHeight = 120;
    public ShipMotion Motion { get; private set; }
    public event EventHandler MotionChanged, SelectionChanged, CursorMoved;

    public HeightGraph()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = Color.White;
        ForeColor = Color.FromArgb(54, 93, 112);
        AccessibleName = "一拍内的船高曲线";
        SetMotion(HeightCurve.Default());
    }

    public double Position
    {
        get { return position; }
        set { position = value; Invalidate(); }
    }

    public bool Editable { get { return Motion is HeightCurve; } }
    public bool EqualHeight { get { return flatHeight == tallHeight; } }
    public bool CanDelete { get { return Editable && selected > 0 && selected < keys.Length - 1; } }
    int SegmentIndex { get { return Math.Min(selected, keys.Length - 2); } }
    public HeightSegment Segment { get { return Editable ? keys[SegmentIndex].Segment : HeightSegment.Linear; } }

    public void SetHeightRange(double flat, double tall)
    {
        flatHeight = flat;
        tallHeight = tall;
        Invalidate();
    }

    public void SetMotion(ShipMotion motion)
    {
        LoadMotion(motion);
        Select(Math.Max(0, Array.FindIndex(keys, key => key.Time == motion.PeakTime)));
        NotifyMotionChanged();
    }

    void LoadMotion(ShipMotion motion)
    {
        Motion = motion;
        HeightCurve height = motion as HeightCurve;
        keys = height == null ? new HeightKey[0] : height.Keys;
    }

    void Select(int i)
    {
        selected = i;
        Invalidate();
        if (SelectionChanged != null) SelectionChanged(this, EventArgs.Empty);
    }

    void NotifyMotionChanged()
    {
        Invalidate();
        if (MotionChanged != null) MotionChanged(this, EventArgs.Empty);
    }

    void EditKeys()
    {
        Motion = new HeightCurve(keys);
        NotifyMotionChanged();
    }

    // Older editors could save a cubic with both handles exactly on the straight line.
    bool StraightHandles
    {
        get
        {
            HeightKey a = keys[SegmentIndex], b = keys[SegmentIndex + 1];
            double third = (b.Pose - a.Pose) / 3;
            return third != 0 && Math.Abs(a.OutPose - (a.Pose + third)) <= Math.Abs(third) * 1e-12 &&
                Math.Abs(b.InPose - (b.Pose - third)) <= Math.Abs(third) * 1e-12;
        }
    }
    public bool Smooth { get { return Segment == HeightSegment.Cosine || (Segment == HeightSegment.Smooth && !StraightHandles); } }

    public void SetSmooth(bool smooth)
    {
        if (!Editable || Smooth == smooth) return;
        HeightKey a = keys[SegmentIndex], b = keys[SegmentIndex + 1];
        if (!smooth)
        {
            a.PreviousSmooth = a.Segment;
            a.Segment = HeightSegment.Linear;
        }
        else
        {
            a.Segment = a.PreviousSmooth == HeightSegment.Cosine ? HeightSegment.Cosine : HeightSegment.Smooth;
            if (a.PreviousSmooth == HeightSegment.Linear || (a.Segment == HeightSegment.Smooth && StraightHandles))
            {
                a.OutPose = a.Pose;
                b.InPose = b.Pose;
            }
            a.PreviousSmooth = HeightSegment.Linear;
        }
        EditKeys();
    }

    public void SelectAdjacentKey(int direction)
    {
        if (keys.Length == 0) return;
        Select(Math.Max(0, Math.Min(selected + direction, keys.Length - 1)));
        Seek(keys[selected].Time);
    }

    public void DeleteSelected()
    {
        if (!CanDelete) return;
        var points = new List<HeightKey>(keys);
        points.RemoveAt(selected);
        HeightCurve.BoundHandles(points[selected - 1], points[selected]);
        keys = points.ToArray();
        Position = keys[--selected].Time;
        EditKeys();
    }

    float Unit { get { return Font.Height / 19f; } }
    RectangleF Plot
    {
        get
        {
            float inset = 66 * Unit;
            return new RectangleF(inset, 30 * Unit, Math.Max(1, Width - inset - 23 * Unit),
                Math.Max(1, Height - 76 * Unit));
        }
    }

    static string Percent(double height) { return height.ToString("G4") + "%"; }

    PointF Pixel(double time, double pose)
    {
        RectangleF plot = Plot;
        return new PointF(plot.Left + (float)time * plot.Width,
            plot.Bottom - (EqualHeight ? 0.5f : (float)pose) * plot.Height);
    }

    PointF KeyPixel(int i) { return Pixel(keys[i].Time, keys[i].Pose); }

    PointF HandlePixel(bool outgoing)
    {
        HeightKey a = keys[SegmentIndex], b = keys[SegmentIndex + 1];
        double time = a.Time + (b.Time - a.Time) * (outgoing ? 1.0 / 3 : 2.0 / 3);
        return Pixel(time, HandlePose(outgoing));
    }

    double HandlePose(bool outgoing)
    {
        HeightKey a = keys[SegmentIndex], b = keys[SegmentIndex + 1];
        if (Segment == HeightSegment.Smooth) return outgoing ? a.OutPose : b.InPose;
        double span = (b.Time - a.Time) / 3;
        return HeightCurve.ClampBetween(outgoing ? a.Pose + Motion.ProgressRate(a.Time, true) * span
            : b.Pose - Motion.ProgressRate(b.Time, false) * span, a.Pose, b.Pose);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
        Graphics g = e.Graphics;
        RectangleF plot = Plot;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.DrawString("船高", Font, Brushes.DarkSlateGray, 5 * Unit, 4 * Unit);
        for (int i = 0; i <= 4; i++)
        {
            double fraction = i / 4.0;
            float x = Pixel(fraction, 0).X;
            g.DrawLine(Pens.Gainsboro, x, plot.Top, x, plot.Bottom);
            string label = (i * 25).ToString() + "%";
            g.DrawString(label, Font, Brushes.DimGray, Math.Min(Width - g.MeasureString(label, Font).Width,
                x - 11 * Unit), plot.Bottom + 5 * Unit);
            if (EqualHeight && i != 2) continue;
            float y = Pixel(0, fraction).Y;
            g.DrawLine(Pens.Gainsboro, plot.Left, y, plot.Right, y);
            g.DrawString(Percent(flatHeight + (tallHeight - flatHeight) * fraction),
                Font, Brushes.DimGray, 5 * Unit, y - Font.Height / 2f);
        }
        g.DrawString("一拍内的时间", Font, Brushes.DarkSlateGray, plot.Left, Height - Font.Height);

        using (var line = new Pen(Color.Gray, 2.4f * Unit))
        {
            if (Editable)
            {
                for (int i = 0; i + 1 < keys.Length; i++)
                {
                    line.Color = i == SegmentIndex ? ForeColor : Color.Gray;
                    line.Width = (i == SegmentIndex ? 3.5f : 1.6f) * Unit;
                    DrawSegment(g, line, keys[i].Time, keys[i + 1].Time);
                }
            }
            else
            {
                DrawSegment(g, line, 0, Motion.PeakTime);
                DrawSegment(g, line, Motion.PeakTime, 1);
            }
        }
        float cursor = Pixel(Position, 0).X;
        g.DrawLine(Pens.Black, cursor, plot.Top, cursor, plot.Bottom + 5 * Unit);
        if (!Editable) return;
        if (!EqualHeight && Smooth)
        {
            foreach (bool outgoing in new[] { true, false })
            {
                PointF handle = HandlePixel(outgoing);
                g.DrawLine(Pens.SlateGray, KeyPixel(SegmentIndex + (outgoing ? 0 : 1)), handle);
                float size = 4 * Unit;
                g.FillRectangle(Brushes.SlateGray, handle.X - size, handle.Y - size, 2 * size, 2 * size);
            }
        }
        for (int i = 0; i < keys.Length; i++)
        {
            PointF p = KeyPixel(i);
            float radius = (i == selected ? 6 : 4) * Unit;
            g.FillEllipse(i == selected ? Brushes.DarkSlateGray : Brushes.Gray,
                p.X - radius, p.Y - radius, 2 * radius, 2 * radius);
        }
    }

    void DrawSegment(Graphics g, Pen pen, double start, double end)
    {
        int steps = Math.Max(2, (int)Math.Ceiling((end - start) * Plot.Width));
        PointF previous = Pixel(start, Motion.ProgressAt(start));
        for (int i = 1; i <= steps; i++)
        {
            double time = start + (end - start) * i / steps;
            PointF next = Pixel(time, Motion.ProgressAt(time));
            g.DrawLine(pen, previous, next);
            previous = next;
        }
    }

    static double DistanceSquared(PointF p, MouseEventArgs e)
    {
        double dx = p.X - e.X, dy = p.Y - e.Y;
        return dx * dx + dy * dy;
    }

    bool GrabControl(MouseEventArgs e)
    {
        if (!Editable) return false;
        double nearest = Math.Pow(8 * Unit, 2);
        int keyIndex = -1;
        for (int i = 0; i < keys.Length; i++)
        {
            double distance = DistanceSquared(KeyPixel(i), e);
            if (distance >= nearest) continue;
            nearest = distance;
            keyIndex = i;
            drag = Drag.Point;
        }
        if (!EqualHeight && Smooth)
        {
            foreach (bool outgoing in new[] { true, false })
            {
                double distance = DistanceSquared(HandlePixel(outgoing), e);
                if (distance >= nearest) continue;
                nearest = distance;
                drag = outgoing ? Drag.OutHandle : Drag.InHandle;
            }
        }
        if (drag == Drag.Point)
        {
            Select(keyIndex);
            Seek(keys[keyIndex].Time);
        }
        return drag != Drag.None;
    }

    double XToTime(int x) { return HeightCurve.ClampBetween((x - Plot.Left) / Plot.Width, 0, 1); }
    double YToPose(int y)
    {
        if (y <= Plot.Top + 4 * Unit) return 1;
        if (y >= Plot.Bottom - 4 * Unit) return 0;
        return (Plot.Bottom - y) / Plot.Height;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();
        drag = Drag.None;
        if (!GrabControl(e))
        {
            double time = XToTime(e.X);
            if (Editable && time > 0 && time < 1 &&
                Math.Abs(e.Y - Pixel(time, Motion.ProgressAt(time)).Y) <= 4 * Unit)
            {
                HeightCurve curve = ((HeightCurve)Motion).Split(time);
                if (curve != Motion)
                {
                    LoadMotion(curve);
                    Select(Array.FindIndex(keys, key => key.Time == time));
                    Seek(time);
                    drag = Drag.Point;
                    NotifyMotionChanged();
                }
            }
            if (drag == Drag.None)
            {
                drag = Drag.Cursor;
                Seek(time);
            }
        }
        Capture = true;
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
        if (drag == Drag.Cursor) { Seek(XToTime(e.X)); return; }
        if (drag == Drag.Point)
        {
            if (!CanDelete) return;
            HeightKey a = keys[selected - 1], point = keys[selected], b = keys[selected + 1];
            double time = XToTime(e.X);
            if (Math.Abs(e.X - Pixel(0.5, 0).X) <= 5 * Unit) time = 0.5;
            if (time > a.Time && time < b.Time) point.Time = time;
            double pose = YToPose(e.Y);
            if (!EqualHeight && pose != point.Pose)
            {
                point.Pose = pose;
                HeightCurve.BoundHandles(a, point);
                HeightCurve.BoundHandles(point, b);
            }
            Position = point.Time;
        }
        else
        {
            HeightKey a = keys[SegmentIndex], b = keys[SegmentIndex + 1];
            if (Segment == HeightSegment.Cosine)
            {
                a.OutPose = HandlePose(true);
                b.InPose = HandlePose(false);
                a.Segment = HeightSegment.Smooth;
            }
            if (drag == Drag.OutHandle) a.OutPose = YToPose(e.Y); else b.InPose = YToPose(e.Y);
            HeightCurve.BoundHandles(a, b);
            Position = a.Time + (b.Time - a.Time) * (drag == Drag.OutHandle ? 1.0 / 3 : 2.0 / 3);
        }
        EditKeys();
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
