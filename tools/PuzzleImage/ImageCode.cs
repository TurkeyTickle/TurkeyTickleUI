using System.Text;

namespace TurkeyTickle.PuzzleImage;

/// <summary>
/// The image code TurkeyTickleUI_Puzzle reads; see the format notes in its Codec.lua.
/// </summary>
internal static class ImageCode
{
    public const int MinSide = 8;
    public const int MaxSide = 320;
    public const int MaxColors = 64;

    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    private const string Tag = "TTPZ1:";
    private const char Run = '~';
    private const int MinRun = 3;
    private const int MaxRun = MinRun + 63;
    private static readonly int[] LevelSteps = [4, 2, 1];

    // Must match the pacing in the addon's Comm.lua.
    private const int Payload = 240;
    private const int Overhead = 40;
    private const int BurstBytes = 2000;
    private const int BytesPerSecond = 800;
    private const int Prefixes = 4;
    private const int PrefixBurst = 10;

    /// <param name="width">Picture width in pixels.</param>
    /// <param name="height">Picture height in pixels.</param>
    /// <param name="palette">24-bit RGB colors.</param>
    /// <param name="pixels">Row-major palette indices.</param>
    public static string Encode(int width, int height, IReadOnlyList<int> palette, byte[] pixels)
    {
        var code = new StringBuilder(Tag);
        AppendNumber(code, width, 2);
        AppendNumber(code, height, 2);
        AppendNumber(code, palette.Count - 1, 1);
        foreach (var rgb in palette)
        {
            AppendNumber(code, rgb, 4);
        }

        var order = PixelOrder(width, height);
        var i = 0;
        while (i < order.Count)
        {
            var color = pixels[order[i]];
            var run = 1;
            while (i + run < order.Count && run < MaxRun && pixels[order[i + run]] == color)
            {
                run++;
            }

            if (run >= MinRun)
            {
                code.Append(Run).Append(Alphabet[run - MinRun]).Append(Alphabet[color]);
            }
            else
            {
                run = 1;
                code.Append(Alphabet[color]);
            }

            i += run;
        }

        return code.ToString();
    }

    public static double SendSeconds(int chars)
    {
        var messages = (chars + Payload - 1) / Payload;
        var byBytes = Math.Max(0, chars + (messages * Overhead) - BurstBytes) / (double)BytesPerSecond;
        var byPrefix = Math.Max(0, messages - (PrefixBurst * Prefixes)) / (double)Prefixes;
        return Math.Max(byBytes, byPrefix);
    }

    // Coarse to fine: every 4th pixel, then every 2nd, then the rest.
    private static List<int> PixelOrder(int width, int height)
    {
        var order = new List<int>(width * height);
        int? coarser = null;
        foreach (var step in LevelSteps)
        {
            for (var y = 0; y < height; y += step)
            {
                for (var x = 0; x < width; x += step)
                {
                    if (coarser is not { } c || x % c != 0 || y % c != 0)
                    {
                        order.Add((y * width) + x);
                    }
                }
            }

            coarser = step;
        }

        return order;
    }

    private static void AppendNumber(StringBuilder code, int value, int digits)
    {
        for (var shift = 6 * (digits - 1); shift >= 0; shift -= 6)
        {
            code.Append(Alphabet[(value >> shift) & 63]);
        }
    }
}
