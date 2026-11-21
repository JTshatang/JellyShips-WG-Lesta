using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// Only model descriptors in this package's allowlist can be changed.
public static class EffectBindings
{
    private static readonly string[] Modes = { "11", "01", "10", "00" };
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    private static readonly Regex Model = new Regex(@"^[A-Za-z0-9_]+/ship/[A-Za-z0-9_.-]+_ports[A-Za-z0-9_.-]*\.model$");
    private static readonly Regex Visual = new Regex(@"<nodefullVisual>([^<>]+)</nodefullVisual>");
    private static readonly Regex Digest = new Regex("^[0-9a-f]{64}$");

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string source, string target, uint flags);

    public static void Write(string path, byte[] data)
    {
        string temp = Path.Combine(Path.GetDirectoryName(path), ".qb-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllBytes(temp, data);
            // Rename on the same volume. A game scanner can briefly hold the destination.
            for (int attempt = 0; !MoveFileEx(temp, path, 0x1); attempt++)
            {
                int error = Marshal.GetLastWin32Error();
                if (attempt >= 5 || (error != 5 && error != 32 && error != 33))
                    throw new IOException(path, new Win32Exception(error));
                Thread.Sleep(100 * (attempt + 1));
            }
        }
        finally { File.Delete(temp); }
    }

    public static void Apply(string root, string previous, string mode, bool verifyOnly)
    {
        int target = Array.IndexOf(Modes, mode);
        int source = Array.IndexOf(Modes, previous);
        if (target < 0) throw new InvalidDataException("特效设置无效。");
        using (SHA256 sha = SHA256.Create())
        foreach (string row in File.ReadLines(Path.Combine(root, "effect-models.tsv"), Utf8))
        {
            string[] fields = row.Split('\t');
            if (fields.Length != 5 || !Model.IsMatch(fields[0]))
                throw new InvalidDataException("特效模型清单无效。");
            string choice = fields[target + 1];
            if (source >= 0 && fields[source + 1] == choice) continue;
            string path = Path.Combine(root, fields[0]);
            string local = "PnFMods/JellyShips04Coverage/" + fields[0].Substring(0, fields[0].Length - ".model".Length);
            string desired = choice == fields[1] ? fields[1] : local;
            string model = File.ReadAllText(path, Utf8);
            Match current = Visual.Match(model);
            if (!current.Success || (current.Groups[1].Value != fields[1] && current.Groups[1].Value != local))
                throw new InvalidDataException("模型引用与安装包不符：" + fields[0]);
            string visualPath = Path.ChangeExtension(path, ".visual");
            string installed = null;
            if (File.Exists(visualPath))
            {
                installed = Hash(sha, File.ReadAllBytes(visualPath));
                if (Array.IndexOf(fields, installed, 2) < 0)
                    throw new InvalidDataException("此处已有其他挂点文件：" + visualPath);
            }
            if (desired == local && installed != choice)
            {
                if (!Digest.IsMatch(choice)) throw new InvalidDataException("挂点清单无效：" + fields[0]);
                byte[] data = File.ReadAllBytes(Path.Combine(root, "EffectVisuals", choice + ".template"));
                if (Hash(sha, data) != choice) throw new InvalidDataException("挂点文件损坏：" + fields[0]);
                if (!verifyOnly) Write(visualPath, data);
            }
            if (verifyOnly) continue;
            if (current.Groups[1].Value != desired)
            {
                string changed = model.Substring(0, current.Groups[1].Index) + desired
                    + model.Substring(current.Groups[1].Index + current.Groups[1].Length);
                Write(path, Utf8.GetBytes(changed));
            }
            if (desired != local && installed != null) File.Delete(visualPath);
        }
    }

    private static string Hash(SHA256 sha, byte[] data)
    {
        return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
    }
}
