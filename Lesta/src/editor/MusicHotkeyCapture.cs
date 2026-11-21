using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class MusicHotkeyCapture : IDisposable
{
    private static readonly KeysConverter KeyNames = new KeysConverter();
    private readonly Form owner;
    private readonly MusicKeyboardHook keyboard;
    private int heldKey;
    private int recording;

    public MusicHotkeyCapture(Form owner)
    {
        this.owner = owner;
        keyboard = new MusicKeyboardHook(ObserveKey);
    }

    public bool Active { get; private set; }
    public event Action<int> KeyPressed;

    public static string Describe(int binding)
    {
        int key = binding & 0xFF;
        string name = KeyNames.ConvertToInvariantString((Keys)key);
        if (name.StartsWith("Oem", StringComparison.OrdinalIgnoreCase))
        {
            const uint keyToCharacter = 2;
            char symbol = (char)(MapVirtualKey((uint)key, keyToCharacter) & 0xFFFF);
            if (!Char.IsControl(symbol) && !Char.IsWhiteSpace(symbol))
                name = symbol.ToString();
        }
        return GameMusicHotkeys.Describe(binding, name);
    }

    public bool Start()
    {
        recording++;
        Active = keyboard.Start();
        return Active;
    }

    public void Stop()
    {
        recording++;
        Active = false;
        if (heldKey == 0)
            keyboard.Dispose();
    }

    public void Dispose()
    {
        heldKey = 0;
        Stop();
    }

    private bool ObserveKey(int key, bool down)
    {
        if (!owner.IsHandleCreated || MusicKeyboardHook.ForegroundWindow() != owner.Handle)
            return false;
        if (key == heldKey)
        {
            if (!down)
            {
                heldKey = 0;
                if (!Active) keyboard.Dispose();
            }
            return true;
        }
        if (!Active || !down || MusicKeyboardHook.IsModifier(key))
            return false;
        if (heldKey == 0)
        {
            heldKey = key;
            QueueKey(MusicKeyboardHook.ReadBinding(key));
        }
        return true;
    }

    private void QueueKey(int binding)
    {
        int current = recording;
        // A registered global shortcut can consume the normal key message.
        // Check registration and update the controls after returning from the hook.
        owner.BeginInvoke((MethodInvoker)delegate {
            if (Active && recording == current && owner.IsHandleCreated &&
                MusicKeyboardHook.ForegroundWindow() == owner.Handle && KeyPressed != null)
                KeyPressed(binding);
        });
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern uint MapVirtualKey(uint key, uint mapType);
}
