using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

// One horizontal scale for the pose samples, the playhead and both edit handles.
public sealed class BeatTimeline : Control
{
    enum Drag { None, Seek, Hold, Peak }
    Drag drag;
    double offset;
    public ShipMotion Motion { get; set; }
    public Image Bow { get; set; }
    public double[] Ratios { get; set; }
    public double Position { get; set; }
    public double RequestedTime { get; private set; }
    public event EventHandler SeekRequested, HoldRequested, PeakRequested;

    public BeatTimeline()
    {
        DoubleBuffered = ResizeRedraw = true;
        BackColor = Color.White;
        ForeColor = Color.FromArgb(54, 93, 112);
        AccessibleName = "动画时间轴";
    }

    float X(double t) { return Width * (.09f + .82f * (float)t); }
    double Time(int x) { return (x - X(0)) / (X(1) - X(0)); }
    HeightCurve Simple
    {
        get { var c = Motion as HeightCurve; return c != null && c.HasSimpleTiming ? c : null; }
    }
    public string PeakLabel
    {
        get { return Ratios[0] != Ratios[2] ? "最高" : Ratios[1] != Ratios[3] ? "最窄" : "第二姿态"; }
    }
    public string LowLabel
    {
        get { return Ratios[0] != Ratios[2] ? "最扁" : Ratios[1] != Ratios[3] ? "最宽" : "原姿态"; }
    }

    Rectangle HandleBounds(bool peak)
    {
        float w = Font.Height * 6.5f, h = Height * .155f;
        float center = X(peak ? Simple.PeakTime : Simple.HoldEnd);
        return Rectangle.Round(new RectangleF(Math.Max(1, Math.Min(Width - w - 1, center - w / 2)),
            Height * (peak ? .645f : .827f), w, h));
    }

    void CenterText(Graphics g, string text, float x, float y, Color color)
    {
        Size size = TextRenderer.MeasureText(g, text, Font);
        TextRenderer.DrawText(g, text, Font, new Point((int)(x - size.Width / 2f), (int)y), color);
    }

    void DrawPose(Graphics g, double time, float center, string label)
    {
        double p = Motion.ProgressAt(time);
        if (Bow != null)
        {
            double h = Ratios[0] + (Ratios[2] - Ratios[0]) * p;
            double w = Ratios[1] + (Ratios[3] - Ratios[1]) * p;
            double fit = Math.Min(Width * .12 / (Bow.Width * Math.Max(Ratios[1], Ratios[3])),
                Height * .20 / (Bow.Height * Math.Max(Ratios[0], Ratios[2])));
            float width = (float)(Bow.Width * fit * w), height = (float)(Bow.Height * fit * h);
            if (width > 0 && height > 0)
                g.DrawImage(Bow, center - width / 2, Height * .21f - height, width, height);
        }
        CenterText(g, label, center, Height * .22f, ForeColor);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle);
        if (Motion == null || Ratios == null) return;
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        double middle = Simple == null ? .5 : Simple.PeakTime;
        DrawPose(g, 0, X(0), LowLabel);
        float poseX = Math.Max(X(.18), Math.Min(X(.82), X(middle)));
        DrawPose(g, middle, poseX, Simple == null ? "半拍" : PeakLabel);
        DrawPose(g, 1, X(1), LowLabel);

        float top = Height * .40f, bottom = Height * .59f;
        if (poseX != X(middle))
            g.DrawLine(Pens.SlateGray, poseX, top - 2, X(middle), top + 1);
        g.DrawLine(Pens.LightGray, X(0), bottom, X(1), bottom);
        g.DrawLine(Pens.LightGray, X(.5), top, X(.5), bottom);
        var previous = new PointF(X(0), bottom);
        int steps = Math.Max(2, (int)(X(1) - X(0)));
        for (int i = 1; i <= steps; ++i)
        {
            double t = (double)i / steps;
            var next = new PointF(X(t), bottom - (float)Motion.ProgressAt(t) * (bottom - top));
            g.DrawLine(Pens.DimGray, previous, next);
            previous = next;
        }
        using (var pen = new Pen(Color.Black, Math.Max(2, Font.Height / 7f)))
            g.DrawLine(pen, X(Position), top - 2, X(Position), bottom + 2);
        if (Simple == null) return;
        foreach (bool peak in new[] { true, false })
        {
            Rectangle handle = HandleBounds(peak);
            int y = handle.Top + handle.Height / 2;
            g.DrawLine(Pens.Silver, X(0), y, X(1), y);
            if (!peak) g.DrawLine(Pens.DimGray, X(0), y, X(Simple.HoldEnd), y);
            g.FillRectangle(Brushes.DarkSlateGray, handle);
            TextRenderer.DrawText(g, "‹ " + (peak ? PeakLabel : LowLabel) + " ›", Font, handle,
                Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        base.OnMouseDown(e);
        Focus();
        drag = Drag.Seek;
        if (Simple != null)
        {
            if (HandleBounds(true).Contains(e.Location)) drag = Drag.Peak;
            else if (HandleBounds(false).Contains(e.Location)) drag = Drag.Hold;
        }
        offset = drag == Drag.Peak ? Simple.PeakTime - Time(e.X) :
            drag == Drag.Hold ? Simple.HoldEnd - Time(e.X) : 0;
        Capture = true;
        if (drag == Drag.Seek) Request(e.X);
        else
        {
            RequestedTime = drag == Drag.Peak ? Simple.PeakTime : Simple.HoldEnd;
            if (SeekRequested != null) SeekRequested(this, EventArgs.Empty);
        }
    }

    void Request(int x)
    {
        RequestedTime = Math.Max(0, Math.Min(1, Time(x) + offset));
        var handler = drag == Drag.Peak ? PeakRequested : drag == Drag.Hold ? HoldRequested : SeekRequested;
        if (handler != null) handler(this, EventArgs.Empty);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (drag != Drag.None) Request(e.X);
        else Cursor = Simple != null && (HandleBounds(true).Contains(e.Location) || HandleBounds(false).Contains(e.Location))
            ? Cursors.SizeWE : Cursors.Cross;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button == MouseButtons.Left) Capture = false;
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        if (!Capture) drag = Drag.None;
        base.OnMouseCaptureChanged(e);
    }
}
