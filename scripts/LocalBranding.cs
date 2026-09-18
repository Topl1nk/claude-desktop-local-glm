// Win32 helpers for local-branding.ps1: give the local Claude window its own taskbar identity
// (separate group, grey icon) and a grey window icon. Compiled at runtime with Add-Type.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class LocalBranding
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; public PROPERTYKEY(Guid g, uint p) { fmtid = g; pid = p; } }

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(8)] public int boolVal;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint c);
        void GetAt(uint i, out PROPERTYKEY k);
        void GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
        void SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
        void Commit();
    }

    static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static PROPERTYKEY PKEY_ID = new PROPERTYKEY(AppUserModel, 5);
    static PROPERTYKEY PKEY_RelaunchCommand = new PROPERTYKEY(AppUserModel, 2);
    static PROPERTYKEY PKEY_RelaunchIconResource = new PROPERTYKEY(AppUserModel, 3);
    static PROPERTYKEY PKEY_RelaunchDisplayNameResource = new PROPERTYKEY(AppUserModel, 4);

    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr LoadImage(IntPtr h, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);

    /// Visible, unowned top-level windows of a process - the ones that get taskbar buttons.
    public static IntPtr[] TopWindows(int pid)
    {
        var list = new List<IntPtr>();
        EnumWindows((h, l) =>
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid && IsWindowVisible(h) && GetWindow(h, 4 /*GW_OWNER*/) == IntPtr.Zero) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    static void SetString(IPropertyStore s, PROPERTYKEY k, string value)
    {
        var v = new PROPVARIANT { vt = 31 /*VT_LPWSTR*/, p = Marshal.StringToCoTaskMemUni(value) };
        try { s.SetValue(ref k, ref v); } finally { Marshal.FreeCoTaskMem(v.p); }
    }

    /// Moves the window into its own taskbar group whose button (and pinned item) uses iconPath.
    public static void SetIdentity(IntPtr hwnd, string appId, string iconPath, string relaunchCommand, string displayName)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore s;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out s));
        try
        {
            // Relaunch properties must be set before the ID for the shell to pick them up together.
            SetString(s, PKEY_RelaunchCommand, relaunchCommand);
            SetString(s, PKEY_RelaunchIconResource, iconPath + ",0");
            SetString(s, PKEY_RelaunchDisplayNameResource, displayName);
            SetString(s, PKEY_ID, appId);
            s.Commit();
        }
        finally { Marshal.ReleaseComObject(s); }
    }

    static IntPtr bigIcon, smallIcon;

    /// Title-bar / Alt+Tab icon.
    public static void SetWindowIcon(IntPtr hwnd, string icoPath)
    {
        if (bigIcon == IntPtr.Zero)
        {
            bigIcon = LoadImage(IntPtr.Zero, icoPath, 1 /*IMAGE_ICON*/, GetSystemMetrics(11), GetSystemMetrics(12), 0x10 /*LR_LOADFROMFILE*/);
            smallIcon = LoadImage(IntPtr.Zero, icoPath, 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x10);
        }
        SendMessage(hwnd, 0x80 /*WM_SETICON*/, (IntPtr)1 /*ICON_BIG*/, bigIcon);
        SendMessage(hwnd, 0x80, IntPtr.Zero /*ICON_SMALL*/, smallIcon);
    }
}
