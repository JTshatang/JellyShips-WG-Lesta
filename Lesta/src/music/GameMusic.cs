using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public enum MusicTrigger { Manual, Battle }

public sealed class GameMusicSession
{
    private string client;
    private long scene;
    private long lastHandledBattle;
    private bool handled;
    private bool manual;

    public MusicTrigger Mode { get; set; }
    public long? Beat { get; private set; }
    public long LastHandledBattle { get { return lastHandledBattle; } }
    public bool Paused { get; private set; }
    public bool Waiting
    {
        get { return client != null && scene != 0 && !Paused && !handled && (manual || Mode == MusicTrigger.Battle); }
    }

    // Scene entry precedes its beat. Invalidate audio when either disappears.
    public bool Observe(string newClient, long newScene, long? beat)
    {
        if (String.IsNullOrEmpty(newClient))
            newClient = null;
        bool clientChanged = client != newClient;
        bool changed = clientChanged || scene != newScene;
        bool lostBeat = Beat.HasValue && Beat != beat;
        if (changed || lostBeat)
            Paused = false;
        if (changed)
        {
            manual = false;
            if (clientChanged)
                lastHandledBattle = 0;
            handled = newScene != 0 && newScene <= lastHandledBattle;
        }
        client = newClient;
        scene = newScene;
        Beat = beat;
        return changed || lostBeat;
    }

    public void Play()
    {
        if (client == null || scene == 0)
            return;
        Paused = false;
        manual = true;
        handled = false;
    }

    public bool Pause()
    {
        if (!Beat.HasValue || Paused)
            return false;
        manual = false;
        Consume();
        Paused = true;
        return true;
    }

    public void Restore(long handledBattle)
    {
        lastHandledBattle = handledBattle;
        handled = scene != 0 && scene <= lastHandledBattle;
    }

    public void Stop()
    {
        Paused = false;
        manual = false;
        Consume();
    }

    public bool TakeStart()
    {
        if (!Waiting || !Beat.HasValue)
            return false;
        manual = false;
        Consume();
        return true;
    }

    private void Consume()
    {
        handled = true;
        lastHandledBattle = Math.Max(lastHandledBattle, scene);
    }
}

public sealed class BattleBeatLog
{
    private const string Stamp = "yyyy-MM-dd HH:mm:ss.fff";
    private const string Prefix = ": INFO: [Script] ";
    private const string Mod = "[ModsAPI] [JellyShips20] ";
    private const string DockLoaded = "[Dock3DContext] onSpaceFinishLoading, ('dock',);";
    private const string DrawNotice = "[UISync] [---] FPS limit set:";
    private const double OutputLatencySeconds = 0.055;
    private static readonly Regex World = new Regex(@"^\[BattleLogic\] (\d+); onEnterWorld\(\)");
    private readonly string path;
    private readonly DateTime clientStart;
    private readonly byte[] buffer = new byte[16384];
    private DateTime fileCreated;
    private long offset;
    private byte[] tail = new byte[0];
    private string partial = "";
    private long world;
    private long scene;
    private long? firstBattleDraw;
    private long? start;
    private bool ownShip;
    private bool replay;
    private bool ended;

    public BattleBeatLog(string path, DateTime clientStart)
    {
        this.path = path;
        // Log timestamps have millisecond precision.
        this.clientStart = clientStart.ToLocalTime().AddMilliseconds(-1);
    }

    public long Scene { get { return replay || ended ? 0 : scene; } }
    public long? Beat { get { return ownShip && !replay && !ended ? start : null; } }

    public void Poll()
    {
        try
        {
            using (var log = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                DateTime created = File.GetCreationTimeUtc(path);
                long length = log.Length;
                if (created != fileCreated || length < offset || !MatchesTail(log))
                {
                    ClearBattle();
                    replay = false;
                    offset = 0;
                    tail = new byte[0];
                    partial = "";
                    fileCreated = created;
                }
                if (length == offset)
                    return;
                log.Position = offset;
                while (offset < length)
                {
                    int count = log.Read(buffer, 0, (int)Math.Min(buffer.Length, length - offset));
                    if (count == 0)
                        break;
                    offset += count;
                    string[] lines = (partial + Encoding.ASCII.GetString(buffer, 0, count)).Split('\n');
                    for (int i = 0; i < lines.Length - 1; i++)
                        ReadLine(lines[i].TrimEnd('\r'));
                    partial = lines[lines.Length - 1];
                }
                int tailLength = (int)Math.Min(64, offset);
                if (tailLength != tail.Length)
                    tail = new byte[tailLength];
                log.Position = offset - tailLength;
                for (int i = 0; i < tailLength; i++)
                    tail[i] = (byte)log.ReadByte();
            }
        }
        catch (IOException) { InvalidateBeat(); }
        catch (UnauthorizedAccessException) { InvalidateBeat(); }
    }

    private bool MatchesTail(FileStream log)
    {
        log.Position = offset - tail.Length;
        foreach (byte value in tail)
            if (log.ReadByte() != value)
                return false;
        return true;
    }

    private void InvalidateBeat()
    {
        // A brief read failure invalidates audio and leaves this scene consumed.
        ownShip = false;
        start = null;
    }

    private void ClearBattle()
    {
        scene = 0;
        world = 0;
        firstBattleDraw = null;
        start = null;
        ownShip = false;
        ended = false;
    }

    private void ReadLine(string line)
    {
        if (line.Length <= 23 + Prefix.Length || string.CompareOrdinal(line, 23, Prefix, 0, Prefix.Length) != 0)
            return;
        string message = line.Substring(23 + Prefix.Length);
        if (!message.StartsWith("[Battle", StringComparison.Ordinal) &&
            !message.StartsWith(DrawNotice, StringComparison.Ordinal) &&
            !message.StartsWith(DockLoaded, StringComparison.Ordinal) &&
            !message.StartsWith("[Avatar] -= BATTLE STARTED", StringComparison.Ordinal) &&
            !message.StartsWith("[PlayerAvatar] leave battle", StringComparison.Ordinal) &&
            !message.StartsWith("[ConnectionControl] Clearing all; shouldDisconnect=True", StringComparison.Ordinal) &&
            !message.StartsWith(Mod, StringComparison.Ordinal))
            return;
        DateTime time;
        if (!DateTime.TryParseExact(line.Substring(0, 23), Stamp, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal, out time) || time < clientStart)
            return;

        var entry = World.Match(message);
        if (message.StartsWith(DockLoaded, StringComparison.Ordinal) && (world == 0 || ended))
            ClearBattle();
        else if (entry.Success)
        {
            long id = long.Parse(entry.Groups[1].Value, CultureInfo.InvariantCulture);
            if (world != id)
            {
                ClearBattle();
                world = id;
                scene = time.Ticks;
            }
        }
        else if (message.StartsWith("[BattleReplay] play,", StringComparison.Ordinal))
        {
            replay = true;
            ClearBattle();
        }
        else if (message.StartsWith("[BattleReplay] current battle arena info:", StringComparison.Ordinal))
            replay = false;
        else if (message.StartsWith("[PlayerAvatar] leave battle", StringComparison.Ordinal) ||
            message.StartsWith("[ConnectionControl] Clearing all; shouldDisconnect=True", StringComparison.Ordinal) ||
            message.StartsWith("[BattleLogic] " + world.ToString(CultureInfo.InvariantCulture) + "; onLeaveWorld()", StringComparison.Ordinal))
            ClearBattle();
        else if (message.StartsWith(Mod + "battle ended", StringComparison.Ordinal))
        {
            ended = true;
            start = null;
        }
        else if (Scene != 0 && !ended && !replay)
        {
            if (message.StartsWith(Mod + "own ship covered", StringComparison.Ordinal))
                ownShip = true;
            else if (!firstBattleDraw.HasValue && !start.HasValue &&
                message.StartsWith(DrawNotice, StringComparison.Ordinal) &&
                message.Contains("worldDrawEnabled: True, guiMode: 2)"))
                firstBattleDraw = EventTicks(time);
            else if (!start.HasValue && message.StartsWith("[Avatar] -= BATTLE STARTED =-;", StringComparison.Ordinal))
            {
                // The hull is already cycling during the countdown. Only open the
                // playback gate now. Older logs can lack the battle-draw notice.
                start = firstBattleDraw ?? (EventTicks(time) + SecondsToTicks(0.137 - OutputLatencySeconds));
            }
        }
    }

    private static long EventTicks(DateTime time)
    {
        long before = Stopwatch.GetTimestamp();
        DateTime wall = DateTime.UtcNow;
        long after = Stopwatch.GetTimestamp();
        return before + (after - before) / 2 + SecondsToTicks((time.ToUniversalTime() - wall).TotalSeconds);
    }

    private static long SecondsToTicks(double seconds)
    {
        return (long)Math.Round(seconds * Stopwatch.Frequency);
    }
}
