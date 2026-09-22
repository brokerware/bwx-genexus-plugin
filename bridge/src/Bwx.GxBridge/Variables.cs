using System;
using System.Collections.Generic;
using System.Linq;
using Artech.Architecture.Common.Objects;
using Artech.Common.Diagnostics;
using Artech.Genexus.Common;
using Artech.Genexus.Common.Objects;
using Artech.Genexus.Common.Parts;
using Attribute = Artech.Genexus.Common.Objects.Attribute;

namespace Bwx.GxBridge
{
    /// <summary>
    /// Lectura y alta/baja/modificacion de variables. El tipo se define de una de
    /// cuatro formas, en este orden de precedencia: basado en atributo, basado en
    /// dominio, tipo SDT/BC/externo por ATTCUSTOMTYPE, o tipo basico con largo y
    /// decimales. ATTCUSTOMTYPE se usa tal cual lo devuelve la lectura de otra variable.
    /// </summary>
    internal static class Variables
    {
        const string CustomTypeProperty = "ATTCUSTOMTYPE";

        public sealed class VariableSpec
        {
            public string Name { get; set; }
            public string BasedOnAttribute { get; set; }
            public string BasedOnDomain { get; set; }
            public string CustomType { get; set; }
            public string DataType { get; set; }
            public int? Length { get; set; }
            public int? Decimals { get; set; }
            public bool? IsCollection { get; set; }
            public string Description { get; set; }
        }

        public sealed class WriteRequest
        {
            public string Name { get; set; }
            public string Type { get; set; }
            public List<VariableSpec> Upsert { get; set; } = new List<VariableSpec>();
            public List<string> Remove { get; set; } = new List<string>();
            public string ExpectedHash { get; set; }
        }

        public static List<Dictionary<string, object>> Read(KBObject obj)
        {
            var part = obj.Parts.Get<VariablesPart>();
            if (part == null) return null;
            return part.Variables
                .Where(v => !v.IsStandard)
                .OrderBy(v => v.Name, StringComparer.OrdinalIgnoreCase)
                .Select(Describe)
                .ToList();
        }

        static Dictionary<string, object> Describe(Variable v)
        {
            var d = new Dictionary<string, object>
            {
                ["name"] = v.Name,
                ["dataType"] = v.Type.ToString(),
                ["length"] = v.Length,
                ["decimals"] = v.Decimals,
                ["isCollection"] = v.IsCollection,
                ["autoDefined"] = v.IsAutoDefined,
            };
            if (v.AttributeBasedOn != null) d["basedOnAttribute"] = v.AttributeBasedOn.Name;
            if (v.DomainBasedOn != null) d["basedOnDomain"] = v.DomainBasedOn.Name;
            var custom = SafeCustomType(v);
            if (!string.IsNullOrEmpty(custom)) d["customType"] = custom;
            if (!string.IsNullOrEmpty(v.Description) && v.Description != v.Name) d["description"] = v.Description;
            return d;
        }

        static string SafeCustomType(Variable v)
        {
            try { return v.IsPropertyDefault(CustomTypeProperty) ? null : v.GetPropertyValueString(CustomTypeProperty); }
            catch { return null; }
        }

        public static object Write(WriteRequest input)
        {
            if (input == null || string.IsNullOrWhiteSpace(input.Name))
                throw new BridgeException(400, "falta name");

            var obj = Router.Find(input.Name, input.Type);
            if (!BridgeConfig.Load().CanWrite(obj.Name))
                throw new BridgeException(403, obj.Name + " no esta habilitado para escritura (config.json → WritePrefixes)");

            var part = obj.Parts.Get<VariablesPart>()
                ?? throw new BridgeException(422, obj.TypeDescriptor.Name + " no tiene variables");

            if (!string.IsNullOrEmpty(input.ExpectedHash) &&
                input.ExpectedHash != Router.Hash(BridgeServer.Serialize(Read(obj))))
                throw new BridgeException(409, "las variables cambiaron desde que se leyeron; volver a leerlas");

            var model = obj.Model;
            var changes = new List<string>();
            var undo = new Undo(part);

            try
            {
                foreach (var name in input.Remove ?? new List<string>())
                {
                    var v = part.GetVariable(name.TrimStart('&'))
                        ?? throw new BridgeException(404, "no existe la variable &" + name.TrimStart('&'));
                    if (v.IsStandard) throw new BridgeException(422, "&" + v.Name + " es estandar y no se puede borrar");
                    part.Remove(v);
                    undo.Removed.Add(v);
                    changes.Add("-&" + v.Name);
                }

                foreach (var spec in input.Upsert ?? new List<VariableSpec>())
                {
                    if (string.IsNullOrWhiteSpace(spec.Name)) throw new BridgeException(400, "variable sin nombre");
                    var name = spec.Name.TrimStart('&');
                    var v = part.GetVariable(name);
                    var isNew = v == null;
                    if (isNew)
                    {
                        v = new Variable(name, part);
                        part.Add(v);
                        undo.Added.Add(v);
                    }
                    else
                    {
                        undo.Modified.Add(Tuple.Create(v, ToSpec(Describe(v))));
                    }
                    Apply(model, v, spec);
                    changes.Add((isNew ? "+&" : "~&") + name);
                }
            }
            catch
            {
                undo.Run(model);
                throw;
            }

            var messages = new OutputMessages();
            if (!obj.Validate(messages) || messages.HasErrors)
            {
                undo.Run(model);
                return new { saved = false, messages = Router.Texts(messages) };
            }

            obj.Save();
            Log.Write("variables " + obj.Name + ": " + string.Join(" ", changes));
            var after = Read(obj);
            return new
            {
                saved = true,
                changes,
                variablesHash = Router.Hash(BridgeServer.Serialize(after)),
                messages = Router.Texts(messages),
            };
        }

        static void Apply(KBModel model, Variable v, VariableSpec spec)
        {
            if (!string.IsNullOrWhiteSpace(spec.BasedOnAttribute))
            {
                v.AttributeBasedOn = Attribute.Get(model, spec.BasedOnAttribute)
                    ?? throw new BridgeException(404, "no existe el atributo " + spec.BasedOnAttribute);
            }
            else if (!string.IsNullOrWhiteSpace(spec.BasedOnDomain))
            {
                v.DomainBasedOn = Domain.Get(model, new QualifiedName(spec.BasedOnDomain))
                    ?? throw new BridgeException(404, "no existe el dominio " + spec.BasedOnDomain);
            }
            else if (!string.IsNullOrWhiteSpace(spec.CustomType))
            {
                v.SetPropertyValue(CustomTypeProperty, v.GetPropertyValueFromString(CustomTypeProperty, spec.CustomType));
            }
            else if (!string.IsNullOrWhiteSpace(spec.DataType))
            {
                if (!Enum.TryParse(spec.DataType, true, out eDBType type))
                    throw new BridgeException(400, "dataType desconocido: " + spec.DataType +
                        " (usar NUMERIC, CHARACTER, VARCHAR, LONGVARCHAR, DATE, DATETIME, Boolean, GUID...)");
                v.AttributeBasedOn = null;
                v.DomainBasedOn = null;
                v.Type = type;
                if (spec.Length.HasValue) v.Length = spec.Length.Value;
                if (spec.Decimals.HasValue) v.Decimals = spec.Decimals.Value;
            }

            if (spec.IsCollection.HasValue) v.IsCollection = spec.IsCollection.Value;
            if (spec.Description != null) v.Description = spec.Description;
        }

        static VariableSpec ToSpec(Dictionary<string, object> d)
        {
            string S(string k) => d.TryGetValue(k, out var x) ? x as string : null;
            return new VariableSpec
            {
                Name = S("name"),
                BasedOnAttribute = S("basedOnAttribute"),
                BasedOnDomain = S("basedOnDomain"),
                CustomType = S("customType"),
                DataType = S("dataType"),
                Length = (int)d["length"],
                Decimals = (int)d["decimals"],
                IsCollection = (bool)d["isCollection"],
                Description = S("description"),
            };
        }

        /// <summary>
        /// Deja la parte como estaba si el cambio no valida. No se confia en que el
        /// objeto se descarte: el modelo puede devolver la misma instancia en el
        /// proximo request, y un cambio a medias terminaria guardado con otro.
        /// </summary>
        sealed class Undo
        {
            readonly VariablesPart _part;
            public readonly List<Variable> Added = new List<Variable>();
            public readonly List<Variable> Removed = new List<Variable>();
            public readonly List<Tuple<Variable, VariableSpec>> Modified = new List<Tuple<Variable, VariableSpec>>();

            public Undo(VariablesPart part) { _part = part; }

            public void Run(KBModel model)
            {
                foreach (var v in Added) _part.Remove(v);
                foreach (var v in Removed) _part.Add(v);
                for (var i = Modified.Count - 1; i >= 0; i--)
                {
                    try { Apply(model, Modified[i].Item1, Modified[i].Item2); }
                    catch (Exception ex) { Log.Write("undo &" + Modified[i].Item1.Name + ": " + ex.Message); }
                }
            }
        }
    }
}
