using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class GameMusicHotkeys : IDisposable
{
    private const int Alt = 1;
    private const int Control = 2;
    private const int Shift = 4;
    private const int KeyMarker = 0x10000;
    private readonly ConcurrentQueue<string> actions = new ConcurrentQueue<string>();
    private Thread listener;
    private uint listenerId;
    private int process;
    private int pause;
    private int play;
    public int Conflicts { get; private set; }

    public static int MakeKey(int key, bool ctrl, bool alt, bool shift)
    {
        if (key < 0x08 || key >= 0xFF || MusicKeyboardHook.IsModifier(key))
            return 0;
        int modifiers = (ctrl ? Control : 0) | (alt ? Alt : 0) | (shift ? Shift : 0);
        return KeyMarker | (modifiers << 8) | key;
    }

    public static int Normalize(int value)
    {
        if (value >= 5 && value <= 11)
            return MakeKey(0x6F + value, true, true, false);
        if ((value & ~0x7FF) != KeyMarker)
            return 0;
        int modifiers = value >> 8;
        return MakeKey(value & 0xFF, (modifiers & Control) != 0, (modifiers & Alt) != 0, (modifiers & Shift) != 0);
    }

    public static string Describe(int binding, string keyName)
    {
        int modifiers = binding >> 8;
        return ((modifiers & Control) != 0 ? "Ctrl+" : "") +
            ((modifiers & Alt) != 0 ? "Alt+" : "") +
            ((modifiers & Shift) != 0 ? "Shift+" : "") + keyName;
    }

    public static bool CanRegister(int binding)
    {
        const int probeId = 3;
        uint key = (uint)(binding & 0xFF);
        uint modifiers = (uint)((binding >> 8) & 7);
        // F12 is reserved for debuggers. Probe registration without keeping the key.
        if (key == 0x7B || !RegisterHotKey(IntPtr.Zero, probeId, modifiers, key))
            return false;
        UnregisterHotKey(IntPtr.Zero, probeId);
        return true;
    }

    public static bool IsForeground(int processId)
    {
        uint foreground;
        GetWindowThreadProcessId(MusicKeyboardHook.ForegroundWindow(), out foreground);
        return processId != 0 && foreground == processId;
    }

    public void Configure(int processId, int pauseKey, int playKey)
    {
        if (processId == 0 || (pauseKey == 0 && playKey == 0))
        {
            Dispose();
            return;
        }
        if (process == processId && pause == pauseKey && play == playKey)
            return;
        Dispose();
        process = processId;
        pause = pauseKey;
        play = playKey;
        using (var ready = new ManualResetEvent(false))
        {
            listener = new Thread(() => Listen(ready)) { IsBackground = true };
            listener.Start();
            ready.WaitOne();
        }
    }

    private void Listen(ManualResetEvent ready)
    {
        listenerId = GetCurrentThreadId();
        Message message;
        PeekMessage(out message, IntPtr.Zero, 0, 0, 0); // Create the thread queue before signaling ready.
        int usablePause = pause;
        int usablePlay = play;
        if (pause != 0 && !CanRegister(pause))
        {
            Conflicts |= 1;
            usablePause = 0;
        }
        if (play != 0 && (play == pause || !CanRegister(play)))
        {
            Conflicts |= 2;
            usablePlay = 0;
        }

        bool pauseHeld = MusicKeyboardHook.IsDown(usablePause & 0xFF);
        bool playHeld = MusicKeyboardHook.IsDown(usablePlay & 0xFF);
        using (var keyboard = new MusicKeyboardHook((key, down) => {
            if (Match(usablePause, key, down, ref pauseHeld)) actions.Enqueue("TogglePause");
            if (Match(usablePlay, key, down, ref playHeld)) actions.Enqueue("Play");
            return false; // Let Korabli receive its own keys as usual.
        }))
        {
            bool active = (usablePause != 0 || usablePlay != 0) && keyboard.Start();
            if (!active)
                Conflicts |= (pause != 0 ? 1 : 0) | (play != 0 ? 2 : 0);
            ready.Set();
            if (active)
                while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { }
        }
    }

    private bool Match(int binding, int key, bool down, ref bool held)
    {
        if (binding == 0 || (binding & 0xFF) != key)
            return false;
        bool newPress = down && !held;
        held = down;
        return newPress && IsForeground(process) && MusicKeyboardHook.ReadBinding(key) == binding;
    }

    public string TakeAction()
    {
        string action;
        return actions.TryDequeue(out action) ? action : null;
    }

    public void Dispose()
    {
        if (listener == null)
            return;
        PostThreadMessage(listenerId, 0x12, UIntPtr.Zero, IntPtr.Zero); // WM_QUIT
        listener.Join();
        listener = null;
        process = 0;
        Conflicts = 0;
        while (TakeAction() != null) { }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr Window;
        public uint Kind;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
        public uint Private;
    }

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint flags);
    [DllImport("user32.dll")]
    private static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint thread, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
}

internal sealed class MusicKeyboardHook : IDisposable
{
    private readonly HookProcedure onKey;
    private readonly Func<int, bool, bool> readKey;
    private IntPtr hook;

    public MusicKeyboardHook(Func<int, bool, bool> readKey)
    {
        this.readKey = readKey;
        onKey = Observe;
    }

    public bool Start()
    {
        const int lowLevelKeyboard = 13;
        if (hook == IntPtr.Zero)
            hook = SetWindowsHookEx(lowLevelKeyboard, onKey, GetModuleHandle(null), 0);
        return hook != IntPtr.Zero;
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
    }

    public static bool IsModifier(int key)
    {
        return key >= 0x10 && key <= 0x12 || key >= 0xA0 && key <= 0xA5 || key == 0x5B || key == 0x5C;
    }

    public static bool IsDown(int key)
    {
        return GetAsyncKeyState(key) < 0;
    }

    public static int ReadBinding(int key)
    {
        if (IsDown(0x5B) || IsDown(0x5C))
            return 0;
        return GameMusicHotkeys.MakeKey(key, IsDown(0x11), IsDown(0x12), IsDown(0x10));
    }

    public static IntPtr ForegroundWindow()
    {
        return GetForegroundWindow();
    }

    private IntPtr Observe(int code, IntPtr message, IntPtr data)
    {
        if (code == 0)
        {
            int kind = message.ToInt32();
            bool down = kind == 0x100 || kind == 0x104;
            // The first field of KBDLLHOOKSTRUCT is the virtual-key code.
            if ((down || kind == 0x101 || kind == 0x105) && readKey(Marshal.ReadInt32(data), down))
                return new IntPtr(1);
        }
        return CallNextHookEx(hook, code, message, data);
    }

    private delegate IntPtr HookProcedure(int code, IntPtr message, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SetWindowsHookEx(int id, HookProcedure proc, IntPtr module, uint threadId);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr handle, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string module);
}
