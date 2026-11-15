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

    /// <returns>The program that took the text, or null if none worked.</returns>
    public static string? TryCopy(string text)
    {
        foreach (var command in Commands)
        {
            var start = new ProcessStartInfo(command[0]) { RedirectStandardInput = true, UseShellExecute = false };
            foreach (var argument in command.Skip(1))
            {
                start.ArgumentList.Add(argument);
            }

            try
            {
                using var process = Process.Start(start);
                if (process is null)
                {
                    continue;
                }

                process.StandardInput.Write(text);
                process.StandardInput.Close();
                if (process.WaitForExit(5000) && process.ExitCode == 0)
                {
                    return command[0];
                }
            }
            catch (Win32Exception)
            {
                // Not installed; try the next one.
            }
        }

        return null;
    }
}
