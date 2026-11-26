using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Artech.Architecture.Common.Objects;
using Artech.Architecture.UI.Framework.Services;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Historial de commits del GeneXus Server: lo mismo que muestra Team Development > History
    /// (numero, fecha, usuario, comentario y objetos de cada commit).
    ///
    /// Solo lectura. Usa el servicio de Team Development del IDE, con la conexion al server
    /// que el IDE ya tiene; no hace update ni commit, y no toca la KB local.
    ///
    /// El server devuelve los commits paginados, del mas nuevo al mas viejo. Cada pagina se
    /// pide en una llamada separada al hilo de UI para no tenerlo bloqueado todo el recorrido.
    /// </summary>
    internal static class History
    {
        const int DefaultMaxPages = 40;

        public static object Read(HttpRequest req)
        {
            var versionName = req.Param("version");
            var query = req.Param("query") ?? "";
            var from = ParseDate(req.Param("from"), "from");
            var to = ParseDate(req.Param("to"), "to");
            var toExclusive = to?.AddDays(1);
            var maxPages = ParseInt(req.Param("maxPages"), "maxPages") ?? DefaultMaxPages;
            var onlyPage = ParseInt(req.Param("page"), "page");
            var firstPage = onlyPage ?? ParseInt(req.Param("firstPage"), "firstPage") ?? 1;

            if (!UIServices.IsTeamDevClientAvailable || UIServices.TeamDevClient == null)
                throw new BridgeException(503, "Team Development no esta disponible en el IDE");

            var version = Ui.Run(() => ResolveVersion(versionName));

            var seen = new HashSet<int>();
            var revisions = new List<object>();
            var pagesRead = 0;
            var reachedFrom = false;
            var exhausted = false;
            DateTime? oldestSeen = null;

            for (var page = firstPage; pagesRead < maxPages; page++)
            {
                var current = page;
                var batch = Ui.Run(() =>
                    (UIServices.TeamDevClient.GetRevisions(version, query, current) ?? Enumerable.Empty<IKBVersionRevision>())
                    .Select(Describe)
                    .ToList());
                pagesRead++;

                var fresh = batch.Where(r => seen.Add(r.Id)).ToList();
                if (fresh.Count == 0) { exhausted = true; break; }

                foreach (var r in fresh)
                {
                    if (oldestSeen == null || r.Date < oldestSeen) oldestSeen = r.Date;
                    if (from.HasValue && r.Date < from.Value) { reachedFrom = true; continue; }
                    if (toExclusive.HasValue && r.Date >= toExclusive.Value) continue;
                    revisions.Add(r.ToJson());
                }

                if (onlyPage.HasValue || reachedFrom) break;
            }

            return new
            {
                version = version.Name,
                query,
                from = from?.ToString("yyyy-MM-dd"),
                to = to?.ToString("yyyy-MM-dd"),
                firstPage,
                pagesRead,
                // Completo: se llego a commits anteriores a "from", o el server no devolvio mas.
                complete = onlyPage.HasValue || reachedFrom || exhausted || !from.HasValue,
                oldestSeen = oldestSeen?.ToString("s"),
                count = revisions.Count,
                revisions,
            };
        }

        sealed class Revision
        {
            public int Id;
            public DateTime Date;
            public string User;
            public string Comment;
            public bool Disabled;
            public List<object> Objects;

            public object ToJson() => new
            {
                id = Id,
                date = Date.ToString("s"),
                user = User,
                comment = Comment,
                disabled = Disabled,
                objects = Objects,
            };
        }

        static Revision Describe(IKBVersionRevision r) => new Revision
        {
            Id = r.RevisionId,
            Date = r.CommitDate,
            User = r.UserName,
            Comment = r.Comment,
            Disabled = r.IsDisabled,
            Objects = (r.Actions ?? Enumerable.Empty<IRevisionAction>())
                .Select(a => (object)new
                {
                    name = a.Name,
                    type = a.Type,
                    description = a.Description,
                    operation = a.Operation.ToString(),
                    user = a.UserName,
                    timestamp = a.Timestamp.ToString("s"),
                })
                .ToList(),
        };

        /// <summary>
        /// Sin nombre, la version del modelo abierto (la que el IDE muestra por defecto en
        /// History). Con nombre, se busca en todo el arbol de versiones de la KB.
        /// </summary>
        static KBVersion ResolveVersion(string name)
        {
            var model = UIServices.KB?.CurrentModel ?? throw new BridgeException(503, "no hay KB abierta en el IDE");
            var current = model.KBVersion ?? model.KB.DesignModel.KBVersion;
            if (string.IsNullOrWhiteSpace(name))
                return current ?? throw new BridgeException(404, "el modelo abierto no tiene version; indicar version");

            var root = current ?? model.KB.DesignModel.KBVersion;
            while (root?.Parent != null) root = root.Parent;

            var all = new List<KBVersion>();
            Collect(root, all);
            var match = all.FirstOrDefault(v => string.Equals(v.Name, name, StringComparison.OrdinalIgnoreCase));
            if (match == null)
                throw new BridgeException(404, "no existe la version " + name + ". Versiones: " +
                    string.Join(", ", all.Select(v => v.Name)));
            return match;
        }

        static void Collect(KBVersion v, List<KBVersion> into)
        {
            if (v == null || into.Contains(v)) return;
            into.Add(v);
            foreach (var child in v.NestedVersions ?? Enumerable.Empty<KBVersion>()) Collect(child, into);
        }

        static DateTime? ParseDate(string value, string param)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            if (DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                return d;
            throw new BridgeException(400, param + " tiene que tener formato yyyy-MM-dd");
        }

        static int? ParseInt(string value, string param)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            if (int.TryParse(value, out var n) && n >= 0) return n;
            throw new BridgeException(400, param + " tiene que ser un entero >= 0");
        }
    }
}
