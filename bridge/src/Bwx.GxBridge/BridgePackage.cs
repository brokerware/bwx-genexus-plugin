using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Artech.Architecture.Common.Packages;
using Artech.Architecture.Common.Services;

[assembly: Package(typeof(Bwx.GxBridge.BridgePackage), IsUIPackage = false)]
[assembly: PackageCompatibility(Version = 143920)]
[assembly: Guid("3b8f2d61-7c4e-4a0b-9f1d-52a6e7c3b914")]

namespace Bwx.GxBridge
{
    /// <summary>
    /// Punto de entrada que GeneXus instancia al cargar los packages. Solo levanta el
    /// servidor dentro del IDE: el mismo package se carga tambien en MSBuild, donde no
    /// hay KB abierta que exponer.
    /// </summary>
    [Guid("a41c9e07-5d2b-4f86-b3e8-0c7d19f4a625")]
    public class BridgePackage : AbstractPackage
    {
        public override string Name => "Bwx.GxBridge";

        public override void Initialize(IGxServiceProvider services)
        {
            base.Initialize(services);

            var process = Process.GetCurrentProcess().ProcessName;
            if (!process.Equals("GeneXus", StringComparison.OrdinalIgnoreCase))
                return;

            try
            {
                Ui.Capture();
                BridgeServer.Start();
            }
            catch (Exception ex)
            {
                // Un fallo del bridge no puede impedir que el IDE arranque.
                Log.Write("no se pudo iniciar: " + ex);
            }
        }
    }
}
