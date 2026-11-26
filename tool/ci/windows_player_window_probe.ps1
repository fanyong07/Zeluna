[CmdletBinding(DefaultParameterSetName = 'Probe')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Probe')][int]$ProcessId,
  [Parameter(ParameterSetName = 'Probe')]
  [ValidateSet('inspect', 'normal', 'maximize', 'key-f', 'key-escape')]
  [string]$Action = 'inspect',
  [Parameter(Mandatory = $true, ParameterSetName = 'Compile')][string]$CompileTo
)
$ErrorActionPreference = 'Stop'
# The integration test compiles a temporary windowless observer once. Direct
# invocation remains available for independent manual Win32 inspection.
$source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Web.Script.Serialization;
public static class ZelunaPlayerWindowProbe {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int Size; public RECT Monitor,Work; public uint Flags; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT { public int Length,Flags,ShowCmd; public POINT Min,Max; public RECT Normal; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc c,IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h,EnumProc c,IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h,ref WINDOWPLACEMENT p);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h,uint f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h,ref MONITORINFO m);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int z,uint f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c,uint t);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  public static IntPtr Find(uint pid) {
    IntPtr best=IntPtr.Zero; long area=-1;
    EnumWindows((h,p)=>{uint owner; GetWindowThreadProcessId(h,out owner); RECT r;
      if(owner==pid && IsWindowVisible(h) && GetWindowRect(h,out r)) {
        long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top); if(a>area){best=h;area=a;}
      } return true;},IntPtr.Zero); return best;
  }
  public static IntPtr FlutterView(IntPtr top) {
    IntPtr result=IntPtr.Zero;
    EnumChildWindows(top,(h,p)=>{var name=new StringBuilder(256);GetClassName(h,name,256);
      if(name.ToString()=="FLUTTERVIEW") result=h; return true;},IntPtr.Zero);
    return result;
  }

  private static int[] Values(RECT r) { return new int[]{r.Left,r.Top,r.Right,r.Bottom}; }
  public static string Observe(int pid, string action) {
    if (action != "inspect" && action != "normal" && action != "maximize" &&
        action != "key-f" && action != "key-escape") throw new ArgumentException("Unsupported action.");
    SetProcessDpiAwarenessContext(new IntPtr(-4));
    using (var process = Process.GetProcessById(pid)) {
      if (process.ProcessName != "Zeluna") throw new InvalidOperationException("Target must be the Zeluna integration-test process.");
    }
    IntPtr window=Find((uint)pid);
    if (window==IntPtr.Zero) throw new InvalidOperationException("No visible target window.");
    var monitor=new MONITORINFO();monitor.Size=Marshal.SizeOf(monitor);
    if (!GetMonitorInfo(MonitorFromWindow(window,2),ref monitor)) throw new InvalidOperationException("GetMonitorInfo failed.");
    if (action=="normal") {
      ShowWindow(window,9);
      int width=Math.Min(1100,monitor.Work.Right-monitor.Work.Left-100);
      int height=Math.Min(720,monitor.Work.Bottom-monitor.Work.Top-100);
      if (!SetWindowPos(window,IntPtr.Zero,monitor.Work.Left+40,monitor.Work.Top+40,width,height,0x14)) throw new InvalidOperationException("SetWindowPos failed.");
    } else if (action=="maximize") {
      ShowWindow(window,3);
    } else if (action=="key-f" || action=="key-escape") {
      // Target only the requested test window. Never inject global keyboard input.
      if (GetForegroundWindow()!=window) {
        SetForegroundWindow(window);
        Thread.Sleep(200);
      }
      if (GetForegroundWindow()!=window) throw new InvalidOperationException("Test window is not foreground; input refused.");
      IntPtr view=FlutterView(window);
      if (view==IntPtr.Zero) throw new InvalidOperationException("Flutter view not found.");
      int key=action=="key-f" ? 0x46 : 0x1B;
      long down=1L | ((long)MapVirtualKey((uint)key,0)<<16);
      long up=0xC0000000L | down;
      if (!PostMessage(view,0x100,new IntPtr(key),new IntPtr(down))) throw new InvalidOperationException("Key down dispatch failed.");
      Thread.Sleep(75);
      if (!PostMessage(view,0x101,new IntPtr(key),new IntPtr(up))) throw new InvalidOperationException("Key up dispatch failed.");
    }
    if(action!="inspect")Thread.Sleep(200);
    RECT rect;
    var placement=new WINDOWPLACEMENT();placement.Length=Marshal.SizeOf(placement);
    if(!GetWindowRect(window,out rect) || !GetWindowPlacement(window,ref placement)) throw new InvalidOperationException("Window snapshot failed.");
    long style=GetWindowLongPtr(window,-16).ToInt64();
    return new JavaScriptSerializer().Serialize(new Dictionary<string,object>{
      {"processId",pid},{"action",action},{"window",window.ToInt64()},
      {"targetForeground",GetForegroundWindow()==window},
      {"rect",Values(rect)},{"monitor",Values(monitor.Monitor)},
      {"style",style},{"extendedStyle",GetWindowLongPtr(window,-20).ToInt64()},
      {"caption",(style & 0x00C00000L)!=0},{"thickFrame",(style & 0x00040000L)!=0},
      {"maximized",IsZoomed(window)},{"showCommand",placement.ShowCmd},{"normalRect",Values(placement.Normal)}
    });
  }
  [STAThread]
  public static int Main(string[] args) {
    if(args.Length!=3)return 2;
    string json;int code=0;
    try { json=Observe(int.Parse(args[0]),args[1]); }
    catch(Exception error) {
      json=new JavaScriptSerializer().Serialize(new Dictionary<string,object>{{"error",error.Message}});
      code=1;
    }
    // A GUI-subsystem helper creates no console, so it cannot steal player focus.
    // Explicit response files also avoid Windows PowerShell stdin host quirks.
    try {
      using(var stream=new FileStream(args[2],FileMode.CreateNew,FileAccess.Write))
      using(var writer=new StreamWriter(stream,new UTF8Encoding(false)))writer.Write(json);
    } catch { return 3; }
    return code;
  }
}
"@
if ($PSCmdlet.ParameterSetName -eq 'Compile') {
  if (Test-Path -LiteralPath $CompileTo) { throw 'Refusing to overwrite an existing helper.' }
  Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly $CompileTo -OutputType WindowsApplication
} else {
  Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Web.Extensions'
  [ZelunaPlayerWindowProbe]::Observe($ProcessId, $Action)
}
