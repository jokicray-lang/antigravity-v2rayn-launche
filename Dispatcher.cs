// SPDX-License-Identifier: MIT
// Built locally with Windows PowerShell / .NET Framework; no VBScript dependency.
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Windows.Forms;

internal static class Dispatcher
{
    private static string JsonString(string value)
    {
        StringBuilder result = new StringBuilder("\"");
        foreach (char c in value)
        {
            switch (c)
            {
                case '\\': result.Append("\\\\"); break;
                case '"': result.Append("\\\""); break;
                case '\r': result.Append("\\r"); break;
                case '\n': result.Append("\\n"); break;
                case '\t': result.Append("\\t"); break;
                default:
                    if (c < 32) result.Append("\\u" + ((int)c).ToString("x4"));
                    else result.Append(c);
                    break;
            }
        }
        return result.Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            string script = Path.Combine(directory, "Start-Antigravity.ps1");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"";
            StringBuilder json = new StringBuilder("[");
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0) json.Append(',');
                json.Append(JsonString(args[i]));
            }
            start.EnvironmentVariables["ANTIGRAVITY_PROXY_ARGS_JSON"] = json.Append(']').ToString();
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            using (Process child = Process.Start(start))
            {
                var output = child.StandardOutput.ReadToEndAsync();
                var error = child.StandardError.ReadToEndAsync();
                child.WaitForExit();
                // Logging must not turn an otherwise successful launch into a failure.
                try { File.WriteAllText(Path.Combine(directory, "last-launch.log"), output.Result + error.Result, Encoding.UTF8); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                if (child.ExitCode != 0)
                    MessageBox.Show("Antigravity proxy launch failed (code " + child.ExitCode + ").\r\nCheck that your proxy is running. See last-launch.log in:\r\n" + directory,
                        "Antigravity Proxy Launcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Antigravity Proxy Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
