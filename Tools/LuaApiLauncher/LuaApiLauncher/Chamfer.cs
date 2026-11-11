using System.Windows;
using System.Windows.Media;

namespace LuaApiLauncher;

public static class Chamfer
{
    // Chamfer: cuts at top-right and bottom-left by `cut`.
    public static Geometry Rect(double w, double h, double cut)
    {
        cut = Math.Max(0, Math.Min(cut, Math.Min(w, h) / 2));
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            c.BeginFigure(new Point(0, 0), true, true);
            c.LineTo(new Point(w - cut, 0), true, false);
            c.LineTo(new Point(w, cut), true, false);
            c.LineTo(new Point(w, h), true, false);
            c.LineTo(new Point(cut, h), true, false);
            c.LineTo(new Point(0, h - cut), true, false);
        }
        g.Freeze();
        return g;
    }
}
