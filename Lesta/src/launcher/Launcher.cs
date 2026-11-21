using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Windows.Forms;

internal static class Launcher
{
    private static void CheckPath(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("启动器位置包含其他程序建立的链接，请核对游戏目录。");
    }

    private static string HashFile(string path)
    {
        CheckPath(path);
        using (SHA256 sha = SHA256.Create())
        using (Stream stream = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    [STAThread]
    private static void Main()
    {
        try
        {
            DirectoryInfo portal = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            if (portal.Name != "莱斯塔-保持Q弹" || portal.Parent == null ||
                !String.Equals(portal.Parent.Name, "res_mods", StringComparison.OrdinalIgnoreCase))
                throw new IOException("请把整个「莱斯塔-保持Q弹」文件夹放进莱服当前构建的 res_mods，然后双击其中的 EXE。");

            CheckPath(portal.FullName);
            string components = Path.Combine(portal.FullName, "组件");
            CheckPath(components);
            string pointer = Path.Combine(components, "program.txt");
            if (File.Exists(pointer))
            {
                CheckPath(pointer);
                string[] lines = File.ReadAllLines(pointer);
                if (lines.Length != 2 || !Regex.IsMatch(lines[0], @"\Aprogram-[0-9a-f]{64}\z") ||
                    !Regex.IsMatch(lines[1], @"\A[0-9a-f]{64}\z"))
                    throw new IOException("程序版本记录无效，请重新解压完整玩家包。");
                // A manually replaced base package takes precedence over its old update pointer.
                if (String.Equals(HashFile(Path.Combine(components, "package.json")), lines[1], StringComparison.OrdinalIgnoreCase))
                {
                    components = Path.Combine(components, lines[0]);
                    CheckPath(components);
                    if (!String.Equals(HashFile(Path.Combine(components, "package.json")), lines[0].Substring(8), StringComparison.OrdinalIgnoreCase))
                        throw new IOException("更新组件的版本记录已改变，请重新解压完整玩家包。");
                }
            }
            string script = Path.Combine(components, "Launcher.ps1");
            if (!File.Exists(script)) throw new IOException("启动组件缺失，请重新解压完整玩家包。");
            CheckPath(script);
            string shell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            Process.Start(new ProcessStartInfo(shell, "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"")
            {
                WorkingDirectory = Environment.SystemDirectory,
                UseShellExecute = false,
                CreateNoWindow = true
            });
        }
        catch (Exception e)
        {
            MessageBox.Show(e.Message, "莱斯塔-保持Q弹", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }
}
