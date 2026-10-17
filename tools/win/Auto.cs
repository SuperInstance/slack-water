
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Auto {
    [StructLayout(LayoutKind.Sequential)] public struct MI { public int dx, dy; public uint md, f, t; public IntPtr e; }
    [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk, sc; public uint f, t; public IntPtr e; }
    [StructLayout(LayoutKind.Explicit)] public struct IU { [FieldOffset(0)] public MI mi; [FieldOffset(0)] public KI ki; }
    [StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public IU u; }

    [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] p, int s);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out System.Drawing.Point p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
    [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

    // SetCursorPos + SendInput moves the cursor but Studio (Qt) never sees the
    // click land. Posting the window messages directly at the client rect
    // sidesteps the cursor and the desktop entirely.
    public static void PostClick(IntPtr h, int cx, int cy) {
        IntPtr lp = (IntPtr)((cy << 16) | (cx & 0xFFFF));
        PostMessage(h, 0x0200, IntPtr.Zero, lp);   // WM_MOUSEMOVE
        System.Threading.Thread.Sleep(150);
        PostMessage(h, 0x0201, (IntPtr)1, lp);    // WM_LBUTTONDOWN, MK_LBUTTON
        System.Threading.Thread.Sleep(110);
        PostMessage(h, 0x0202, IntPtr.Zero, lp);  // WM_LBUTTONUP
    }

    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }

    static int SZ = Marshal.SizeOf(typeof(IN));

    public static void Mouse(uint flags) {
        IN i = new IN(); i.type = 0; i.u.mi.f = flags;
        SendInput(1, new IN[] { i }, SZ);
    }

    public static void ClickAt(int sx, int sy) {
        SetCursorPos(sx, sy);
        System.Threading.Thread.Sleep(200);
        Mouse(0x0002);              // LEFTDOWN
        System.Threading.Thread.Sleep(90);
        Mouse(0x0004);              // LEFTUP
    }

    public static void Tap(ushort vk) {
        KI d = new KI(); d.vk = vk;
        IN i1 = new IN(); i1.type = 1; i1.u.ki = d;
        KI u = new KI(); u.vk = vk; u.f = 0x0002;
        IN i2 = new IN(); i2.type = 1; i2.u.ki = u;
        SendInput(2, new IN[] { i1, i2 }, SZ);
    }

    // Studio's stop shortcut is Shift+F5 and F5 is the play shortcut. A bare
    // Tap() cannot express the modifier, and clicking the toolbar has proved
    // unreliable while a play session has the cursor captured.
    public static void TapShifted(ushort vk) {
        keybd_event(0x10, 0, 0, IntPtr.Zero);   // SHIFT down
        System.Threading.Thread.Sleep(120);
        Tap(vk);
        System.Threading.Thread.Sleep(120);
        keybd_event(0x10, 0, 2, IntPtr.Zero);   // SHIFT up
    }

    // Repeat a key. Roblox's default camera is keyboard-rotational on the arrow
    // keys and WASD drives the character, so repeated taps are the only way to
    // steer the view when synthetic mouse input is not landing.
    public static void TapN(ushort vk, int count, int gapMs) {
        for (int i = 0; i < count; i++) {
            Tap(vk);
            System.Threading.Thread.Sleep(gapMs);
        }
    }

    // Hold a key down for a while, for walking.
    public static void Hold(ushort vk, int ms) {
        keybd_event((byte)vk, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(ms);
        keybd_event((byte)vk, 0, 2, IntPtr.Zero);
    }

    // Press a modifier and a key together (Ctrl+Down and friends).
    public static void Chord(ushort mod, ushort vk) {
        keybd_event((byte)mod, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(90);
        Tap(vk);
        System.Threading.Thread.Sleep(90);
        keybd_event((byte)mod, 0, 2, IntPtr.Zero);
    }

    // Type literal text. KEYEVENTF_UNICODE delivers characters independently of
    // the active keyboard layout, which matters because this machine is not US
    // layout and a scan-code based "print $x" would come out as gibberish.
    public static void TypeText(string s) {
        foreach (char c in s) {
            KI down = new KI();
            down.vk = 0; down.sc = (ushort)c; down.f = 0x0004;   // KEYEVENTF_UNICODE
            KI up = new KI();
            up.vk = 0; up.sc = (ushort)c; up.f = 0x0004 | 0x0002; // ... | KEYEVENTF_KEYUP
            IN i1 = new IN(); i1.type = 1; i1.u.ki = down;
            IN i2 = new IN(); i2.type = 1; i2.u.ki = up;
            SendInput(2, new IN[] { i1, i2 }, SZ);
            System.Threading.Thread.Sleep(14);
        }
    }

    // Windows foreground lock: a background process cannot steal focus with a
    // bare SetForegroundWindow. Synthesising ALT first grants temporary
    // foreground rights.
    public static void ForceFocus(IntPtr h) {
        ShowWindow(h, 9);
        keybd_event(0x12, 0, 0, IntPtr.Zero);
        keybd_event(0x12, 0, 2, IntPtr.Zero);
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(600);
    }
}
