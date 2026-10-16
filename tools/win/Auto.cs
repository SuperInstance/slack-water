
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
