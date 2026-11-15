namespace TurkeyTickle.PuzzleImage;

/// <summary>Reduces an image to a small palette: median cut, refined with a few k-means passes.</summary>
internal static class Quantizer
{
    private const int RefinePasses = 5;

    /// <returns>The palette (0xRRGGBB, only colors that are used) and each pixel's palette index.</returns>
    public static (int[] Palette, byte[] Indices) Reduce(RgbImage image, int maxColors, bool dither)
    {
        var counts = new Dictionary<int, int>();
        foreach (var rgb in image.Pixels)
        {
            counts[rgb] = counts.GetValueOrDefault(rgb) + 1;
        }

        var colors = counts.Select(kv => new Weighted(kv.Key, kv.Value)).ToArray();
        int[] palette;
        if (colors.Length <= maxColors)
        {
            palette = [.. colors.Select(c => c.Rgb)];
            dither = false;
        }
        else
        {
            palette = MedianCut(colors, maxColors);
            for (var pass = 0; pass < RefinePasses; pass++)
            {
                palette = Refine(colors, palette);
            }
        }

        var indices = dither ? MapDithered(image, palette) : MapNearest(image.Pixels, palette);
        return Compact(palette, indices);
    }

    private readonly record struct Weighted(int Rgb, int Count);

    private static int Channel(int rgb, int channel) => (rgb >> (16 - (8 * channel))) & 255;

    private static int Distance(int r1, int g1, int b1, int r2, int g2, int b2)
    {
        int dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
        return (2 * dr * dr) + (4 * dg * dg) + (3 * db * db);
    }

    private static int Nearest(IReadOnlyList<int> palette, int r, int g, int b)
    {
        var best = 0;
        var bestDistance = int.MaxValue;
        for (var i = 0; i < palette.Count; i++)
        {
            var p = palette[i];
            var distance = Distance(r, g, b, (p >> 16) & 255, (p >> 8) & 255, p & 255);
            if (distance < bestDistance)
            {
                best = i;
                bestDistance = distance;
            }
        }

        return best;
    }

    private static int[] MedianCut(Weighted[] colors, int maxColors)
    {
        var boxes = new List<Weighted[]> { colors };
        while (boxes.Count < maxColors)
        {
            var bestBox = -1;
            var bestChannel = 0;
            long bestScore = 0;
            for (var i = 0; i < boxes.Count; i++)
            {
                if (boxes[i].Length < 2)
                {
                    continue;
                }

                long total = boxes[i].Sum(c => (long)c.Count);
                for (var channel = 0; channel < 3; channel++)
                {
                    var range = boxes[i].Max(c => Channel(c.Rgb, channel)) - boxes[i].Min(c => Channel(c.Rgb, channel));
                    if (range * total > bestScore)
                    {
                        (bestBox, bestChannel, bestScore) = (i, channel, range * total);
                    }
                }
            }

            if (bestBox < 0)
            {
                break;
            }

            var box = boxes[bestBox].OrderBy(c => Channel(c.Rgb, bestChannel)).ToArray();
            long half = box.Sum(c => (long)c.Count) / 2, running = 0;
            var split = 1;
            for (; split < box.Length - 1; split++)
            {
                running += box[split - 1].Count;
                if (running >= half)
                {
                    break;
                }
            }

            boxes[bestBox] = box[..split];
            boxes.Add(box[split..]);
        }

        return [.. boxes.Select(Mean)];
    }

    private static int Mean(IEnumerable<Weighted> colors)
    {
        long r = 0, g = 0, b = 0, n = 0;
        foreach (var c in colors)
        {
            r += (long)Channel(c.Rgb, 0) * c.Count;
            g += (long)Channel(c.Rgb, 1) * c.Count;
            b += (long)Channel(c.Rgb, 2) * c.Count;
            n += c.Count;
        }

        return (int)(((r / n) << 16) | ((g / n) << 8) | (b / n));
    }

    private static int[] Refine(Weighted[] colors, int[] palette)
    {
        var groups = new List<Weighted>[palette.Length];
        foreach (var c in colors)
        {
            var i = Nearest(palette, Channel(c.Rgb, 0), Channel(c.Rgb, 1), Channel(c.Rgb, 2));
            (groups[i] ??= []).Add(c);
        }

        return [.. palette.Select((rgb, i) => groups[i] is { } group ? Mean(group) : rgb)];
    }

    private static byte[] MapNearest(int[] pixels, int[] palette)
    {
        var cache = new Dictionary<int, byte>();
        var indices = new byte[pixels.Length];
        for (var i = 0; i < pixels.Length; i++)
        {
            var rgb = pixels[i];
            if (!cache.TryGetValue(rgb, out var index))
            {
                index = (byte)Nearest(palette, Channel(rgb, 0), Channel(rgb, 1), Channel(rgb, 2));
                cache[rgb] = index;
            }

            indices[i] = index;
        }

        return indices;
    }

    // Floyd-Steinberg error diffusion.
    private static byte[] MapDithered(RgbImage image, int[] palette)
    {
        var (width, height) = (image.Width, image.Height);
        var error = new float[(width + 2) * 2 * 3];
        var indices = new byte[width * height];
        for (var y = 0; y < height; y++)
        {
            var current = (y % 2) * (width + 2) * 3;
            var next = ((y + 1) % 2) * (width + 2) * 3;
            Array.Clear(error, next, (width + 2) * 3);
            for (var x = 0; x < width; x++)
            {
                var rgb = image.Pixels[(y * width) + x];
                var at = current + ((x + 1) * 3);
                var r = Math.Clamp((int)Math.Round(Channel(rgb, 0) + error[at]), 0, 255);
                var g = Math.Clamp((int)Math.Round(Channel(rgb, 1) + error[at + 1]), 0, 255);
                var b = Math.Clamp((int)Math.Round(Channel(rgb, 2) + error[at + 2]), 0, 255);
                var index = Nearest(palette, r, g, b);
                indices[(y * width) + x] = (byte)index;

                var p = palette[index];
                Span<float> diff = [r - Channel(p, 0), g - Channel(p, 1), b - Channel(p, 2)];
                for (var c = 0; c < 3; c++)
                {
                    error[at + 3 + c] += diff[c] * 7 / 16;
                    error[next + (x * 3) + c] += diff[c] * 3 / 16;
                    error[next + ((x + 1) * 3) + c] += diff[c] * 5 / 16;
                    error[next + ((x + 2) * 3) + c] += diff[c] * 1 / 16;
                }
            }
        }

        return indices;
    }

    private static (int[] Palette, byte[] Indices) Compact(int[] palette, byte[] indices)
    {
        var remap = new int[palette.Length];
        Array.Fill(remap, -1);
        var used = new List<int>();
        foreach (var index in indices)
        {
            if (remap[index] < 0)
            {
                remap[index] = used.Count;
                used.Add(palette[index]);
            }
        }

        for (var i = 0; i < indices.Length; i++)
        {
            indices[i] = (byte)remap[indices[i]];
        }

        return ([.. used], indices);
    }
}
