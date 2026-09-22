using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Configuracion en %LOCALAPPDATA%\bwx-gx-bridge\config.json. La lista
    /// WritePrefixes limita que objetos se pueden modificar. El default es solo
    /// ZZBridge*, para probar; "*" habilita toda la KB. Se relee en cada escritura.
    /// </summary>
    internal sealed class BridgeConfig
    {
        public int Port { get; set; }
        public List<string> WritePrefixes { get; set; } = new List<string> { "ZZBridge" };

        public static string Dir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "bwx-gx-bridge");

        static string ConfigPath => Path.Combine(Dir, "config.json");
        static string SessionPath => Path.Combine(Dir, "session.json");

        public static BridgeConfig Load()
        {
            Directory.CreateDirectory(Dir);
            if (!File.Exists(ConfigPath))
            {
                var fresh = new BridgeConfig();
                File.WriteAllText(ConfigPath, new JavaScriptSerializer().Serialize(fresh));
                return fresh;
            }
            try
            {
                return new JavaScriptSerializer().Deserialize<BridgeConfig>(File.ReadAllText(ConfigPath)) ?? new BridgeConfig();
            }
            catch (Exception ex)
            {
                Log.Write("config.json invalido, uso defaults: " + ex.Message);
                return new BridgeConfig();
            }
        }

        public bool CanWrite(string objectName)
        {
            foreach (var prefix in WritePrefixes ?? new List<string>())
            {
                if (prefix == "*") return true;
                if (objectName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        public static void WriteSession(int port, string token)
        {
            Directory.CreateDirectory(Dir);
            var session = new Dictionary<string, object>
            {
                ["port"] = port,
                ["token"] = token,
                ["pid"] = Process.GetCurrentProcess().Id,
                ["started"] = DateTime.Now.ToString("s"),
            };
            File.WriteAllText(SessionPath, new JavaScriptSerializer().Serialize(session));
        }

        public static void DeleteSession()
        {
            try { File.Delete(SessionPath); } catch { }
        }
    }

    internal static class Log
    {
        static readonly object Gate = new object();

        public static void Write(string message)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(BridgeConfig.Dir);
                    File.AppendAllText(Path.Combine(BridgeConfig.Dir, "bridge.log"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine);
                }
            }
            catch { }
        }
    }
}
