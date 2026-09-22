using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Ejecuta trabajo en el hilo de UI del IDE, con tiempo limite.
    ///
    /// No alcanza con Application.OpenForms[0]: al arrancar GeneXus la primera ventana
    /// puede ser una que ya no procesa mensajes (el splash), y un Invoke sobre ella
    /// queda colgado para siempre. Se usa el contexto de sincronizacion capturado al
    /// cargar el package y, si no hay, la ventana principal del proceso.
    /// </summary>
    internal static class Ui
    {
        static readonly TimeSpan Timeout = TimeSpan.FromSeconds(60);
        static SynchronizationContext _context;
        static int _uiThreadId;

        public static void Capture()
        {
            var current = SynchronizationContext.Current;
            if (current is WindowsFormsSynchronizationContext)
            {
                _context = current;
                _uiThreadId = Thread.CurrentThread.ManagedThreadId;
            }
            Log.Write("contexto de UI: " + (current?.GetType().Name ?? "ninguno") +
                      " (hilo " + Thread.CurrentThread.ManagedThreadId + ")");
        }

        public static T Run<T>(Func<T> work)
        {
            if (Thread.CurrentThread.ManagedThreadId == _uiThreadId) return work();

            var done = new ManualResetEventSlim(false);
            var abandoned = 0;
            T result = default;
            Exception failure = null;

            void Body()
            {
                // Si el llamador ya se fue por timeout, no ejecutar: una escritura tardia
                // guardaria algo que el cliente cree rechazado.
                if (Interlocked.CompareExchange(ref abandoned, 0, 0) == 1) return;
                try { result = work(); }
                catch (Exception ex) { failure = ex; }
                finally { done.Set(); }
            }

            if (_context != null)
            {
                _context.Post(_ => Body(), null);
            }
            else
            {
                var target = MainWindow();
                if (target == null || !target.InvokeRequired) return work();
                target.BeginInvoke(new Action(Body));
            }

            if (!done.Wait(Timeout))
            {
                Interlocked.Exchange(ref abandoned, 1);
                throw new BridgeException(503,
                    "el IDE no respondio en " + (int)Timeout.TotalSeconds + " s (¿hay un dialogo abierto o una operacion en curso?)");
            }

            if (failure is BridgeException) throw failure;
            if (failure != null) throw new Exception(failure.Message, failure);
            return result;
        }

        static Control MainWindow()
        {
            var handle = Process.GetCurrentProcess().MainWindowHandle;
            if (handle != IntPtr.Zero)
            {
                var control = Control.FromHandle(handle);
                if (control != null) return control;
            }
            foreach (Form form in Application.OpenForms)
                if (form.Visible && form.IsHandleCreated) return form;
            return null;
        }
    }
}
