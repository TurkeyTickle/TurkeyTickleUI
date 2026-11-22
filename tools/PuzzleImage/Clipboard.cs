using System.ComponentModel;
using System.Diagnostics;

namespace TurkeyTickle.PuzzleImage;

internal static class Clipboard
{
    private static readonly string[][] Commands =
    [
        ["wl-copy"],
        ["xclip", "-selection", "clipboard"],
        ["xsel", "-b", "-i"],
        ["pbcopy"],
        ["clip.exe"],
    ];

    public static bool TryCopy(string text)
    {
        foreach (var command in Commands)
        {
            if (TryRun(command, text))
            {
                return true;
            }
        }

        return OperatingSystem.IsLinux() && TryRun([
            "qdbus6", "org.kde.klipper", "/klipper",
            "org.kde.klipper.klipper.setClipboardContents", text,
        ]);
    }

    private static bool TryRun(string[] command, string? input = null)
    {
        var start = new ProcessStartInfo(command[0])
        {
            RedirectStandardInput = input is not null,
            UseShellExecute = false,
        };
        foreach (var argument in command.Skip(1))
        {
            start.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(start);
            if (process is null)
            {
                return false;
            }

            if (input is not null)
            {
                process.StandardInput.Write(input);
                process.StandardInput.Close();
            }

            return process.WaitForExit(5000) && process.ExitCode == 0;
        }
        catch (Exception e) when (e is Win32Exception or IOException)
        {
            return false;
        }
    }
}
