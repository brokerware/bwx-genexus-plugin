using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Artech.Architecture.Common.Objects;
using Artech.Architecture.UI.Framework.Services;
using Artech.Common.Diagnostics;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Operaciones expuestas. Todo acceso a la KB corre en el hilo de UI del IDE:
    /// es el mismo hilo en el que el usuario edita, asi que no hay carreras con el
    /// editor ni con el modelo en memoria.
    /// </summary>
    internal static class Router
    {
        public static object Dispatch(HttpRequest req, out int status)
        {
            status = 200;
            switch (req.Method + " " + req.Path)
            {
                // /ping no toca el hilo de UI: distingue "bridge caido" de "IDE ocupado".
                case "GET /ping": return new { ok = true, version = typeof(Router).Assembly.GetName().Version.ToString() };
                case "GET /status": return OnUi(Status);
                case "GET /object": return OnUi(() => ReadObject(req.Param("name"), req.Param("type")));
                case "POST /source":
                    var input = BridgeServer.Deserialize<WriteSourceRequest>(req.Body);
                    return OnUi(() => WriteSource(input));
                case "POST /variables":
                    var vars = BridgeServer.Deserialize<Variables.WriteRequest>(req.Body);
                    return OnUi(() => Variables.Write(vars));
                default:
                    throw new BridgeException(404, "ruta desconocida: " + req.Method + " " + req.Path);
            }
        }

        public sealed class WriteSourceRequest
        {
            public string Name { get; set; }
            public string Type { get; set; }
            public string Part { get; set; }
            public string Source { get; set; }
            /// <summary>Hash devuelto por GET /object. Si el fuente cambio desde entonces, se rechaza.</summary>
            public string ExpectedHash { get; set; }
        }

        static object Status()
        {
            var kb = UIServices.KB?.CurrentKB;
            var model = UIServices.KB?.CurrentModel;
            return new
            {
                kbOpen = kb != null,
                kb = kb?.Name,
                kbLocation = kb?.Location,
                model = model?.Name,
                writePrefixes = BridgeConfig.Load().WritePrefixes,
                version = typeof(Router).Assembly.GetName().Version.ToString(),
            };
        }

        static object ReadObject(string name, string type)
        {
            var obj = Find(name, type);
            var parts = new List<object>();
            foreach (KBObjectPart part in obj.Parts)
            {
                var source = part as ISource;
                parts.Add(new
                {
                    name = part.TypeDescriptor.Name,
                    isSource = source != null,
                    source = source?.Source,
                    hash = source != null ? Hash(source.Source) : null,
                });
            }
            var variables = Variables.Read(obj);
            return new
            {
                name = obj.Name,
                type = obj.TypeDescriptor.Name,
                guid = obj.Guid,
                lastUpdate = obj.LastUpdate.ToLocalTime().ToString("s"),
                parts,
                variables,
                variablesHash = variables == null ? null : Hash(BridgeServer.Serialize(variables)),
            };
        }

        static object WriteSource(WriteSourceRequest input)
        {
            if (input == null || string.IsNullOrWhiteSpace(input.Name) || string.IsNullOrWhiteSpace(input.Part) || input.Source == null)
                throw new BridgeException(400, "faltan name, part o source");

            var obj = Find(input.Name, input.Type);
            if (!BridgeConfig.Load().CanWrite(obj.Name))
                throw new BridgeException(403, obj.Name + " no esta habilitado para escritura (config.json → WritePrefixes)");

            var part = obj.Parts.Cast<KBObjectPart>()
                .FirstOrDefault(p => string.Equals(p.TypeDescriptor.Name, input.Part, StringComparison.OrdinalIgnoreCase));
            if (part == null)
                throw new BridgeException(404, obj.Name + " no tiene la parte " + input.Part);
            if (!(part is ISource source))
                throw new BridgeException(422, "la parte " + part.TypeDescriptor.Name + " no es de fuente");

            var before = source.Source;
            if (!string.IsNullOrEmpty(input.ExpectedHash) && input.ExpectedHash != Hash(before))
                throw new BridgeException(409, "el fuente cambio desde que se leyo; volver a leerlo");

            source.Source = input.Source;

            var messages = new OutputMessages();
            var valid = obj.Validate(messages);
            if (!valid || messages.HasErrors)
            {
                // Se deja el objeto como estaba en memoria: nada quedo guardado.
                source.Source = before;
                return new { saved = false, messages = Texts(messages) };
            }

            obj.Save();
            Log.Write("guardado " + obj.TypeDescriptor.Name + " " + obj.Name + " / " + part.TypeDescriptor.Name);
            return new { saved = true, hash = Hash(source.Source), messages = Texts(messages) };
        }

        internal static KBObject Find(string name, string type)
        {
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException(400, "falta name");
            var model = UIServices.KB?.CurrentModel ?? throw new BridgeException(503, "no hay KB abierta en el IDE");

            var matches = model.Objects.GetByName(null, null, name)
                .Where(o => string.Equals(o.Name, name, StringComparison.OrdinalIgnoreCase))
                .Where(o => string.IsNullOrEmpty(type) || string.Equals(o.TypeDescriptor.Name, type, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (matches.Count == 0) throw new BridgeException(404, "no existe " + (type ?? "objeto") + " " + name);
            if (matches.Count > 1)
                throw new BridgeException(409, "nombre ambiguo, indicar type: " +
                    string.Join(", ", matches.Select(m => m.TypeDescriptor.Name)));
            return matches[0];
        }

        internal static List<string> Texts(OutputMessages messages) =>
            messages.Select(m => m.Level + ": " + m.Text).ToList();

        internal static string Hash(string text)
        {
            var normalized = (text ?? "").Replace("\r\n", "\n");
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(normalized))).Replace("-", "").ToLowerInvariant();
        }

        static T OnUi<T>(Func<T> work) => Ui.Run(work);
    }
}
