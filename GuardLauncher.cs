// SPDX-License-Identifier: MIT
// Start the entry-maintenance process without creating a PowerShell console window.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class GuardLauncher
{
    private static void Log(string directory, string text)
    {
        try
        {
            File.AppendAllText(Path.Combine(directory, "guard-launch.log"),
                DateTimeOffset.Now.ToString("o") + " " + text + Environment.NewLine,
                Encoding.UTF8);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    [STAThread]
    private static int Main()
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        try
        {
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""
                + Path.Combine(directory, "Manage-Launcher.ps1")
                + "\" -Watch -InstallDirectory \"" + directory + "\"";
            start.WorkingDirectory = directory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (Process child = Process.Start(start))
            {
                child.StandardInput.Close();
                var output = child.StandardOutput.ReadToEndAsync();
                var error = child.StandardError.ReadToEndAsync();
                Log(directory, "Started guard PID=" + child.Id + " with CreateNoWindow=true.");
                child.WaitForExit();
                if (!String.IsNullOrWhiteSpace(output.Result)) Log(directory, output.Result);
                if (!String.IsNullOrWhiteSpace(error.Result)) Log(directory, error.Result);
                Log(directory, "Guard exited with code " + child.ExitCode + ".");
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            Log(directory, "Launch failed: " + error);
            return 1;
        }
    }
}
