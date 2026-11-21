using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

// Keep the native slider's keyboard and accessibility behavior.
public sealed class VolumeSlider : TrackBar
{
    private const int WmMouseMove = 0x0200;
    private const int LeftDown = 0x0201;
    private const int LeftUp = 0x0202;
    private const int LeftDoubleClick = 0x0203;

    public VolumeSlider()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        AutoSize = false;
        TickStyle = TickStyle.None;
        Maximum = 100;
        LargeChange = 10;
    }

    private int MarginX { get { return Math.Max(1, (int)Math.Round(DeviceDpi * 8.0 / 96)); } }
    private int Travel { get { return Math.Max(1, ClientSize.Width - 2 * MarginX); } }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float dpi = g.DpiX / 96f;
        float t = (Value - Minimum) / (float)Math.Max(1, Maximum - Minimum);
        float center = ClientSize.Height / 2f;
        float thumbX = MarginX + t * Travel;
        float radius = 5f * dpi;
        float thickness = 3f * dpi;
        Color filled = !Enabled ? SystemColors.GrayText :
            SystemInformation.HighContrast ? SystemColors.Highlight : ForeColor;
        using (var rail = new SolidBrush(SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(213, 220, 223)))
        using (var level = new SolidBrush(filled))
        {
            g.FillRectangle(rail, MarginX, center - thickness / 2, Travel, thickness);
            g.FillRectangle(level, MarginX, center - thickness / 2, thumbX - MarginX, thickness);
            g.FillEllipse(level, thumbX - radius, center - radius, 2 * radius, 2 * radius);
        }
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -1, -1));
    }

    protected override void OnValueChanged(EventArgs e)
    {
        base.OnValueChanged(e);
        Invalidate();
    }

    protected override void WndProc(ref Message m)
    {
        // A click on the rail seeks directly. Capture keeps a drag active past either end.
        if (m.Msg == LeftDown || m.Msg == LeftDoubleClick || (Capture && (m.Msg == WmMouseMove || m.Msg == LeftUp)))
        {
            if (m.Msg == LeftDown || m.Msg == LeftDoubleClick)
            {
                Focus();
                Capture = true;
            }
            int x = unchecked((short)m.LParam.ToInt64());
            double t = Math.Max(0, Math.Min(1, (x - MarginX) / (double)Travel));
            Value = Minimum + (int)Math.Round(t * (Maximum - Minimum));
            if (m.Msg == LeftUp)
                Capture = false;
            return;
        }
        base.WndProc(ref m);
    }
}
