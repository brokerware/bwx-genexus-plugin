using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Servidor HTTP minimo sobre TCP en loopback. Se evita HttpListener porque
    /// HTTP.sys exige reservas de URL con permisos de administrador.
    ///
    /// Cada request debe traer el header X-Bridge-Token con el token de la sesion,
    /// que se publica en %LOCALAPPDATA%\bwx-gx-bridge\session.json y cambia en cada
    /// arranque del IDE: solo un proceso del mismo usuario puede leerlo.
    /// </summary>
    internal static class BridgeServer
    {
        const int DefaultPort = 47850;
        const int MaxBodyBytes = 8 * 1024 * 1024;

        static TcpListener _listener;
        static string _token;
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static void Start()
        {
            var config = BridgeConfig.Load();
            _token = NewToken();
            _listener = new TcpListener(IPAddress.Loopback, config.Port > 0 ? config.Port : DefaultPort);
            _listener.Start();
            var port = ((IPEndPoint)_listener.LocalEndpoint).Port;

            BridgeConfig.WriteSession(port, _token);
            AppDomain.CurrentDomain.ProcessExit += (s, e) => BridgeConfig.DeleteSession();

            var thread = new Thread(AcceptLoop) { IsBackground = true, Name = "Bwx.GxBridge" };
            thread.Start();
            Log.Write("escuchando en 127.0.0.1:" + port);
        }

        static void AcceptLoop()
        {
            while (true)
            {
                TcpClient client;
                try { client = _listener.AcceptTcpClient(); }
                catch (Exception ex) { Log.Write("accept: " + ex.Message); return; }
                ThreadPool.QueueUserWorkItem(_ => Handle(client));
            }
        }

        static void Handle(TcpClient client)
        {
            using (client)
            using (var stream = client.GetStream())
            {
                int status;
                object body;
                try
                {
                    var req = HttpRequest.Read(stream, MaxBodyBytes);
                    if (!TokenMatches(req.Header("X-Bridge-Token")))
                    {
                        status = 401;
                        body = new { error = "token invalido" };
                    }
                    else
                    {
                        body = Router.Dispatch(req, out status);
                    }
                }
                catch (BridgeException ex)
                {
                    status = ex.Status;
                    body = new { error = ex.Message };
                }
                catch (Exception ex)
                {
                    Log.Write("request: " + ex);
                    status = 500;
                    body = new { error = ex.GetType().Name + ": " + ex.Message };
                }
                Write(stream, status, Json.Serialize(body));
            }
        }

        static bool TokenMatches(string candidate)
        {
            if (candidate == null || candidate.Length != _token.Length) return false;
            var diff = 0;
            for (var i = 0; i < _token.Length; i++) diff |= candidate[i] ^ _token[i];
            return diff == 0;
        }

        static void Write(Stream stream, int status, string json)
        {
            var payload = Encoding.UTF8.GetBytes(json);
            var head = "HTTP/1.1 " + status + " " + Reason(status) + "\r\n" +
                       "Content-Type: application/json; charset=utf-8\r\n" +
                       "Content-Length: " + payload.Length + "\r\n" +
                       "Connection: close\r\n\r\n";
            var headBytes = Encoding.ASCII.GetBytes(head);
            stream.Write(headBytes, 0, headBytes.Length);
            stream.Write(payload, 0, payload.Length);
        }

        static string Reason(int status)
        {
            switch (status)
            {
                case 200: return "OK";
                case 400: return "Bad Request";
                case 401: return "Unauthorized";
                case 403: return "Forbidden";
                case 404: return "Not Found";
                case 409: return "Conflict";
                case 422: return "Unprocessable Entity";
                case 503: return "Service Unavailable";
                default: return "Error";
            }
        }

        static string NewToken()
        {
            var bytes = new byte[32];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        internal static T Deserialize<T>(string json) => Json.Deserialize<T>(json);
        internal static string Serialize(object value) => Json.Serialize(value);
    }

    internal sealed class BridgeException : Exception
    {
        public int Status { get; }
        public BridgeException(int status, string message) : base(message) { Status = status; }
    }

    internal sealed class HttpRequest
    {
        public string Method;
        public string Path;
        public Dictionary<string, string> Query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string Body = "";

        public string Header(string name) => Headers.TryGetValue(name, out var v) ? v : null;
        public string Param(string name) => Query.TryGetValue(name, out var v) ? v : null;

        public static HttpRequest Read(Stream stream, int maxBody)
        {
            var req = new HttpRequest();
            var requestLine = ReadLine(stream);
            var parts = requestLine.Split(' ');
            if (parts.Length < 2) throw new BridgeException(400, "request line invalida");
            req.Method = parts[0].ToUpperInvariant();

            var target = parts[1];
            var q = target.IndexOf('?');
            req.Path = q < 0 ? target : target.Substring(0, q);
            if (q >= 0)
            {
                foreach (var pair in target.Substring(q + 1).Split('&'))
                {
                    if (pair.Length == 0) continue;
                    var eq = pair.IndexOf('=');
                    var k = Uri.UnescapeDataString(eq < 0 ? pair : pair.Substring(0, eq));
                    var v = eq < 0 ? "" : Uri.UnescapeDataString(pair.Substring(eq + 1).Replace('+', ' '));
                    req.Query[k] = v;
                }
            }

            string line;
            while ((line = ReadLine(stream)).Length > 0)
            {
                var colon = line.IndexOf(':');
                if (colon > 0) req.Headers[line.Substring(0, colon).Trim()] = line.Substring(colon + 1).Trim();
            }

            if (int.TryParse(req.Header("Content-Length"), out var length) && length > 0)
            {
                if (length > maxBody) throw new BridgeException(400, "body demasiado grande");
                var buffer = new byte[length];
                var read = 0;
                while (read < length)
                {
                    var n = stream.Read(buffer, read, length - read);
                    if (n <= 0) break;
                    read += n;
                }
                req.Body = Encoding.UTF8.GetString(buffer, 0, read);
            }
            return req;
        }

        static string ReadLine(Stream stream)
        {
            var sb = new StringBuilder();
            int b;
            while ((b = stream.ReadByte()) >= 0)
            {
                if (b == '\n') break;
                if (b != '\r') sb.Append((char)b);
                if (sb.Length > 16 * 1024) throw new BridgeException(400, "header demasiado largo");
            }
            return sb.ToString();
        }
    }
}
