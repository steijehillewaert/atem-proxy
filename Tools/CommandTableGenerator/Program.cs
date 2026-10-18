// Generates AtemProxyKit/Sources/AtemProxyKit/Generated/CommandTable.swift from LibAtem.
//
// The proxy never decodes command payloads. It only needs to know, for every
// command the ATEM sends, which bytes identify the piece of state it describes
// (LibAtem's [CommandId] properties). That lets the Swift side keep a
// "latest value per state key" cache to replay to newly connected clients.
//
// Usage: dotnet run --project Tools/CommandTableGenerator -- <output.swift>

using System.Reflection;
using System.Text;
using LibAtem;
using LibAtem.Commands;
using LibAtem.Commands.Audio;
using LibAtem.Commands.Audio.Fairlight;
using LibAtem.Commands.DataTransfer;
using LibAtem.Serialization;

var output = args.Length > 0 ? args[0] : "CommandTable.swift";

string NameOf(Type t) => t.GetCustomAttribute<CommandNameAttribute>()!.Name;

var sb = new StringBuilder();
sb.AppendLine("// GENERATED FILE - DO NOT EDIT.");
sb.AppendLine("// Regenerate with: make generate (Tools/CommandTableGenerator, from LibAtem).");
sb.AppendLine();
sb.AppendLine("enum CommandTable {");

// Protocol versions known to LibAtem
sb.AppendLine("    /// Protocol versions known to LibAtem, as (raw value, firmware name).");
sb.AppendLine("    static let knownVersions: [(UInt32, String)] = [");
foreach (var field in typeof(ProtocolVersion).GetFields(BindingFlags.Public | BindingFlags.Static))
{
    var attr = field.GetCustomAttribute<ProtocolVersionNameAttribute>();
    if (attr == null) continue;
    sb.AppendLine($"        (0x{(uint)(int)field.GetValue(null)!:X8}, \"{attr.Name}\"),");
}
sb.AppendLine("    ]");
sb.AppendLine();

// State key layout
sb.AppendLine("    /// Byte ranges (offset, length) of the identifying fields of each ATEM -> client");
sb.AppendLine("    /// command, keyed by four-char name. Entries are (minimum protocol version, ranges),");
sb.AppendLine("    /// sorted ascending. An empty range list means the command holds a single state value.");
sb.AppendLine("    static let stateKeys: [String: [(UInt32, [KeyRange])]] = [");

var all = CommandManager.GetAllTypes();
foreach (var (name, options) in all.OrderBy(kv => kv.Key, StringComparer.Ordinal))
{
    var entries = new List<string>();
    foreach (var (version, type) in options.OrderBy(o => o.Item1))
    {
        var dir = type.GetCustomAttribute<CommandNameAttribute>()!.Direction;
        if (dir == CommandDirection.ToServer) continue;

        List<string>? ranges = new List<string>();
        var props = type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            .Where(p => p.GetCustomAttribute<CommandIdAttribute>() != null)
            .Select(p => (Start: p.GetCustomAttribute<SerializeAttribute>()?.StartByte,
                Size: p.GetCustomAttributes().OfType<SerializableAttributeBase>().FirstOrDefault()?.Size,
                p.Name))
            .OrderBy(p => p.Start);
        foreach (var p in props)
        {
            if (p.Start == null || p.Size == null)
            {
                // Hand written (de)serializer. Not used as cached state, so the proxy treats it as opaque.
                Console.Error.WriteLine($"skip: {name} {type.Name}.{p.Name} has no fixed layout");
                ranges = null;
                break;
            }
            ranges.Add($"KeyRange({p.Start}, {p.Size})");
        }

        if (ranges != null)
            entries.Add($"(0x{(uint)(int)version:X8}, [{string.Join(", ", ranges)}])");
    }

    if (entries.Count > 0)
        sb.AppendLine($"        \"{name}\": [{string.Join(", ", entries)}],");
}
sb.AppendLine("    ]");
sb.AppendLine();

void EmitSet(string swiftName, string doc, IEnumerable<Type> types)
{
    sb.AppendLine($"    /// {doc}");
    var names = types.Select(NameOf).Distinct().OrderBy(n => n, StringComparer.Ordinal);
    sb.AppendLine($"    static let {swiftName}: Set<String> = [{string.Join(", ", names.Select(n => $"\"{n}\""))}]");
}

EmitSet("audioLevelCommands", "High rate audio meter commands, only forwarded to subscribed clients.", new[]
{
    typeof(FairlightMixerMasterLevelsCommand), typeof(FairlightMixerSourceLevelsCommand),
    typeof(FairlightMixerSendLevelsCommand), typeof(AudioMixerLevelsCommand), typeof(AudioMixerSendLevelsCommand)
});
EmitSet("transferCommands", "Media transfer commands. Not supported through the proxy.", new[]
{
    typeof(DataTransferAbortCommand), typeof(DataTransferAckCommand), typeof(DataTransferCompleteCommand),
    typeof(DataTransferDataCommand), typeof(DataTransferErrorCommand), typeof(DataTransferDownloadRequestCommand),
    typeof(DataTransferUploadContinueCommand), typeof(DataTransferUploadRequestCommand)
});
EmitSet("lockCommands", "Media pool lock commands. Not supported through the proxy.", new[]
{
    typeof(LockObtainedCommand), typeof(LockStateSetCommand)
});
sb.AppendLine($"    static let legacyAudioSubscribe = \"{NameOf(typeof(AudioMixerSendLevelsCommand))}\"");
sb.AppendLine($"    static let fairlightAudioSubscribe = \"{NameOf(typeof(FairlightMixerSendLevelsCommand))}\"");
sb.AppendLine("}");

Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
File.WriteAllText(output, sb.ToString());
Console.WriteLine($"Wrote {all.Count} commands to {output}");
