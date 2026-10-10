param([IntPtr]$Hwnd = [IntPtr]::Zero, [int]$DesktopIndex = 1, [switch]$DryRun, [switch]$LoadOnly)
# Move a top-level window of ANY process to virtual desktop N (Windows 11 24H2/25H2 internal API).
# Safety: verifies GetCount() == registry desktop count and every desktop GetId() == registry GUID before MoveViewToDesktop.
$src = @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IServiceProvider10 { [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService(ref Guid service, ref Guid riid); }
[ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IObjectArray { int GetCount(); [PreserveSig] int GetAt(int index, ref Guid iid, out IntPtr obj); }
[ComImport, Guid("3F07F4BE-B107-441A-AF0F-39D82529072C"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktop { bool IsViewVisible(IntPtr view); Guid GetId(); }
[ComImport, Guid("53F5CA0B-158F-4124-900C-057158060B27"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManagerInternal {
  int GetCount();
  [PreserveSig] int MoveViewToDesktop(IntPtr view, IntPtr desktop);
  bool CanViewMoveDesktops(IntPtr view);
  IntPtr GetCurrentDesktop();
  void GetDesktops(out IObjectArray desktops);
}
[ComImport, Guid("1841C6D7-4F9D-42C0-AF41-8747538F10E5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationViewCollection {
  [PreserveSig] int GetViews(out IObjectArray a);
  [PreserveSig] int GetViewsByZOrder(out IObjectArray a);
  [PreserveSig] int GetViewsByAppUserModelId([MarshalAs(UnmanagedType.LPWStr)] string id, out IObjectArray a);
  [PreserveSig] int GetViewForHwnd(IntPtr hwnd, out IntPtr view);
}
public static class VDI {
  public static string Run(IntPtr hwnd, int idx, Guid[] reg, bool dry) {
    var shell = (IServiceProvider10)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2F03A33-21F5-47FA-B4BB-156362A2F239")));
    Guid s1 = new Guid("C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B"); Guid i1 = typeof(IVirtualDesktopManagerInternal).GUID;
    var mgr = (IVirtualDesktopManagerInternal)shell.QueryService(ref s1, ref i1);
    Guid i2 = typeof(IApplicationViewCollection).GUID;
    var views = (IApplicationViewCollection)shell.QueryService(ref i2, ref i2);
    int cnt = mgr.GetCount();
    if (cnt != reg.Length) return "ABORT count " + cnt + " != registry " + reg.Length;
    IObjectArray arr; mgr.GetDesktops(out arr);
    Guid iid = typeof(IVirtualDesktop).GUID; IntPtr target = IntPtr.Zero;
    for (int i = 0; i < cnt; i++) {
      IntPtr p; int hr = arr.GetAt(i, ref iid, out p);
      if (hr != 0) return "ABORT GetAt hr=" + hr.ToString("x");
      var d = (IVirtualDesktop)Marshal.GetObjectForIUnknown(p);
      Guid id = d.GetId();
      if (id != reg[i]) return "ABORT desktop " + i + " id " + id + " != " + reg[i];
      if (i == idx) target = p;
    }
    IntPtr view; int h2 = views.GetViewForHwnd(hwnd, out view);
    if (h2 != 0) return "ABORT GetViewForHwnd hr=" + h2.ToString("x");
    if (dry) return "OK verified " + cnt + " desktops, view " + view;
    int h3 = mgr.MoveViewToDesktop(view, target);
    return "MOVED hr=" + h3.ToString("x");
  }
}
"@
if (-not ('VDI' -as [type])) { Add-Type -TypeDefinition $src }
if ($LoadOnly) { return "loaded" }
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops'
$ids = (Get-ItemProperty $k).VirtualDesktopIDs
$n = $ids.Length / 16
$reg = New-Object 'System.Guid[]' $n
for ($i = 0; $i -lt $n; $i++) { $reg[$i] = [guid]::new([byte[]]$ids[($i*16)..($i*16+15)]) }
[VDI]::Run($Hwnd, $DesktopIndex - 1, $reg, [bool]$DryRun)
