using SkiaSharp;

namespace TurkeyTickle.PuzzleImage;

/// <summary>An image as row-major 0xRRGGBB pixels.</summary>
internal sealed record RgbImage(int Width, int Height, int[] Pixels);

internal static class ImageLoader
{
    public static async Task<byte[]> ReadAsync(string source)
    {
        if (!source.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !source.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return await File.ReadAllBytesAsync(source);
        }

        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 TurkeyTickleUI-puzzle");
        return await http.GetByteArrayAsync(new Uri(source));
    }

    /// <summary>
    /// Decodes, applies the EXIF orientation, flattens transparency onto black and scales the
    /// longest side to <paramref name="longestSide"/>.
    /// </summary>
    public static RgbImage? DecodeScaled(byte[] bytes, int longestSide, int minSide, int maxSide)
    {
        using var data = SKData.CreateCopy(bytes);
        using var codec = SKCodec.Create(data);
        if (codec is null)
        {
            return null;
        }

        using var decoded = SKBitmap.Decode(codec);
        if (decoded is null)
        {
            return null;
        }

        var (matrix, orientedWidth, orientedHeight) = Orientation(codec.EncodedOrigin, decoded.Width, decoded.Height);
        var scale = (double)longestSide / Math.Max(orientedWidth, orientedHeight);
        var width = Math.Clamp((int)Math.Round(orientedWidth * scale), minSide, maxSide);
        var height = Math.Clamp((int)Math.Round(orientedHeight * scale), minSide, maxSide);

        using var oriented = new SKBitmap(new SKImageInfo(orientedWidth, orientedHeight, SKColorType.Rgba8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(oriented))
        {
            canvas.Clear(SKColors.Black);
            canvas.SetMatrix(matrix);
            canvas.DrawBitmap(decoded, 0, 0, new SKSamplingOptions(SKFilterMode.Nearest));
        }

        using var scaled = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(scaled))
        using (var image = SKImage.FromBitmap(oriented))
        {
            canvas.DrawImage(image, new SKRect(0, 0, width, height), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        }

        var pixels = new int[width * height];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var c = scaled.GetPixel(x, y);
                pixels[(y * width) + x] = (c.Red << 16) | (c.Green << 8) | c.Blue;
            }
        }

        return new RgbImage(width, height, pixels);
    }

    public static void SavePreview(string path, int width, int height, IReadOnlyList<int> palette, byte[] indices, int zoom)
    {
        using var small = new SKBitmap(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque));
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var rgb = palette[indices[(y * width) + x]];
                small.SetPixel(x, y, new SKColor((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
            }
        }

        using var large = new SKBitmap(new SKImageInfo(width * zoom, height * zoom, SKColorType.Rgba8888, SKAlphaType.Opaque));
        using (var canvas = new SKCanvas(large))
        using (var image = SKImage.FromBitmap(small))
        {
            canvas.DrawImage(image, new SKRect(0, 0, width * zoom, height * zoom), new SKSamplingOptions(SKFilterMode.Nearest));
        }

        using var png = large.Encode(SKEncodedImageFormat.Png, 100);
        File.WriteAllBytes(path, png.ToArray());
    }

    // Maps the stored pixels to how the photo should be shown, and that view's size.
    private static (SKMatrix Matrix, int Width, int Height) Orientation(SKEncodedOrigin origin, int w, int h) => origin switch
    {
        SKEncodedOrigin.TopRight => (new SKMatrix(-1, 0, w, 0, 1, 0, 0, 0, 1), w, h),
        SKEncodedOrigin.BottomRight => (new SKMatrix(-1, 0, w, 0, -1, h, 0, 0, 1), w, h),
        SKEncodedOrigin.BottomLeft => (new SKMatrix(1, 0, 0, 0, -1, h, 0, 0, 1), w, h),
        SKEncodedOrigin.LeftTop => (new SKMatrix(0, 1, 0, 1, 0, 0, 0, 0, 1), h, w),
        SKEncodedOrigin.RightTop => (new SKMatrix(0, -1, h, 1, 0, 0, 0, 0, 1), h, w),
        SKEncodedOrigin.RightBottom => (new SKMatrix(0, -1, h, -1, 0, w, 0, 0, 1), h, w),
        SKEncodedOrigin.LeftBottom => (new SKMatrix(0, 1, 0, -1, 0, w, 0, 0, 1), h, w),
        _ => (SKMatrix.Identity, w, h),
    };
}
