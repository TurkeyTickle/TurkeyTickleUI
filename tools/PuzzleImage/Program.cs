using TurkeyTickle.PuzzleImage;

const string Usage = """
    Turns an image (web URL or file) into a code for TurkeyTickleUI_Puzzle.
    Paste the code into the addon's host window (/ttpz host).

    usage: puzzle-image <url-or-file> [options]

      --size N         longest side in pixels (8-320, default 192)
      --colors N       palette size (2-64, default 64)
      --dither         dither colors (smoother photos, slightly bigger code)
      --preview FILE   save an enlarged PNG of what players will see
      --out FILE       write the code to a file instead of the clipboard
    """;

string? source = null, previewPath = null, outPath = null;
int size = 192, colors = 64;
var dither = false;
for (var i = 0; i < args.Length; i++)
{
    string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value");
    try
    {
        switch (args[i])
        {
            case "-h" or "--help":
                Console.WriteLine(Usage);
                return 0;
            case "--size":
                size = int.Parse(Next());
                break;
            case "--colors":
                colors = int.Parse(Next());
                break;
            case "--dither":
                dither = true;
                break;
            case "--preview":
                previewPath = Next();
                break;
            case "--out":
                outPath = Next();
                break;
            default:
                source = source is null && !args[i].StartsWith("--", StringComparison.Ordinal)
                    ? args[i]
                    : throw new ArgumentException($"unexpected argument {args[i]}");
                break;
        }
    }
    catch (Exception e) when (e is ArgumentException or FormatException)
    {
        return Fail(e.Message);
    }
}

if (source is null)
{
    return Fail("give an image URL or file");
}

if (size is < ImageCode.MinSide or > ImageCode.MaxSide)
{
    return Fail($"--size must be {ImageCode.MinSide}-{ImageCode.MaxSide}");
}

if (colors is < 2 or > ImageCode.MaxColors)
{
    return Fail($"--colors must be 2-{ImageCode.MaxColors}");
}

RgbImage? image;
try
{
    image = ImageLoader.DecodeScaled(await ImageLoader.ReadAsync(source), size, ImageCode.MinSide, ImageCode.MaxSide);
}
catch (Exception e) when (e is HttpRequestException or IOException or UriFormatException or TaskCanceledException or UnauthorizedAccessException)
{
    return Fail($"couldn't load {source}: {e.Message}");
}

if (image is null)
{
    return Fail($"{source} isn't an image format I can read");
}

var (palette, indices) = Quantizer.Reduce(image, colors, dither);
var code = ImageCode.Encode(image.Width, image.Height, palette, indices);
Console.Error.WriteLine(
    $"{image.Width}x{image.Height} pixels, {palette.Length} colors, {code.Length:N0} characters, " +
    $"about {ImageCode.SendSeconds(code.Length):F0}s to send.");

if (previewPath is not null)
{
    ImageLoader.SavePreview(previewPath, image.Width, image.Height, palette, indices, 4);
    Console.Error.WriteLine($"Preview saved to {previewPath}");
}

if (outPath is not null)
{
    await File.WriteAllTextAsync(outPath, code);
    Console.Error.WriteLine($"Code written to {outPath}");
}
else if (!Console.IsOutputRedirected && Clipboard.TryCopy(code) is not null)
{
    Console.Error.WriteLine("Code copied to the clipboard. In game: /ttpz host, then paste it.");
}
else
{
    Console.WriteLine(code);
}

return 0;

static int Fail(string message)
{
    Console.Error.WriteLine($"puzzle-image: {message}");
    Console.Error.WriteLine("Run puzzle-image --help for usage.");
    return 2;
}
