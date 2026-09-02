using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

internal sealed class DemoAdapterFailureException : Exception
{
    internal DemoAdapterFailureException(string reason) : base(reason) { Reason = reason; }
    internal string Reason { get; private set; }
}

internal sealed class DemoAdapterContext
{
    internal string TaskId;
    internal string InvocationId;
    internal string Action;
    internal int Attempt = -1;
    internal bool FaultInjected;
    internal string ProjectPath;
    internal string VcxProjectPath;
    internal string LogPath;
    internal string ArtifactPath;
    internal string AdapterSha256;
    internal string MsBuildSha256;
    internal string ProjectSha256;
    internal string VcxProjectSha256;
    internal int? NativeExitCode;
    internal string NativeOutput = String.Empty;
    internal string StartedAt;
    internal string FinishedAt;
}

internal static class DemoMsdevAdapter
{
    private const string AsciiBanner = "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION";
    private const string UnicodeBanner = "MSBUILD DEMO ADAPTER \u2014 NOT VC6 QUALIFICATION";
    private const string ProtocolMarker = "TEAM_BOB_MSBUILD_DEMO_PROTOCOL_V1_NOT_VC6";
    private const string Usage = "Usage: DemoMsdevAdapter.exe <sandbox-project.dsp> /MAKE|/REBUILD \"CycleWatch - Win32 Release\" /OUT <log-path>";
    private static readonly Regex TaskIdPattern = new Regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", RegexOptions.CultureInvariant);
    private static readonly Regex InvocationPattern = new Regex("^attempt-(?<attempt>[012])-(?<action>make|rebuild)-(?<token>[0-9a-f]{32})$", RegexOptions.CultureInvariant);

    public static int Main(string[] args)
    {
        DemoAdapterContext context = new DemoAdapterContext();
        context.StartedAt = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture);

        if (args.Length == 1 && String.Equals(args[0], "/?", StringComparison.Ordinal))
        {
            Console.WriteLine(UnicodeBanner);
            Console.WriteLine(Usage);
            return 0;
        }

        try
        {
            ValidateAndPopulateContext(args, context);
            return ExecuteBuild(context);
        }
        catch (DemoAdapterFailureException failure)
        {
            return EmitEnvironmentFailure(context, failure.Reason);
        }
        catch (Exception)
        {
            return EmitEnvironmentFailure(context, "INTERNAL_ERROR");
        }
    }

    private static void ValidateAndPopulateContext(string[] args, DemoAdapterContext context)
    {
        if (args.Length != 5) Fail("ARGUMENT_COUNT");
        string requestedAction;
        string invocationAction;
        if (String.Equals(args[1], "/MAKE", StringComparison.Ordinal))
        {
            requestedAction = "Make";
            invocationAction = "make";
        }
        else if (String.Equals(args[1], "/REBUILD", StringComparison.Ordinal))
        {
            requestedAction = "Rebuild";
            invocationAction = "rebuild";
        }
        else
        {
            Fail("ACTION");
            return;
        }
        if (!String.Equals(args[2], DemoAdapterConfiguration.Target, StringComparison.Ordinal)) Fail("TARGET");
        if (!String.Equals(args[3], "/OUT", StringComparison.Ordinal)) Fail("OUT_SWITCH");

        string sandboxRoot = ValidateExistingRoot(DemoAdapterConfiguration.SandboxRoot, "SANDBOX_ROOT");
        string logRoot = ValidateExistingRoot(DemoAdapterConfiguration.LogRoot, "LOG_ROOT");
        if (AtOrBelow(sandboxRoot, logRoot) || AtOrBelow(logRoot, sandboxRoot)) Fail("ROOT_OVERLAP");

        string projectPath = GetFullLocalPath(args[0], "PROJECT_PATH");
        string logPath = GetFullLocalPath(args[4], "LOG_PATH");
        if (!StrictlyBelow(projectPath, sandboxRoot)) Fail("PROJECT_SCOPE");
        if (!StrictlyBelow(logPath, logRoot)) Fail("LOG_SCOPE");
        if (!File.Exists(projectPath)) Fail("PROJECT_MISSING");
        ValidateNoReparse(projectPath, "PROJECT_REPARSE");

        string projectRelative = RelativeBelow(projectPath, sandboxRoot);
        string[] projectParts = projectRelative.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        if (projectParts.Length != 5 ||
            !String.Equals(projectParts[2], "demo", StringComparison.Ordinal) ||
            !String.Equals(projectParts[3], "CycleWatch", StringComparison.Ordinal) ||
            !String.Equals(projectParts[4], "CycleWatch.dsp", StringComparison.Ordinal))
        {
            Fail("PROJECT_SHAPE");
        }
        string taskId = projectParts[0];
        string invocationId = projectParts[1];
        if (!TaskIdPattern.IsMatch(taskId)) Fail("TASK_ID");
        Match invocationMatch = InvocationPattern.Match(invocationId);
        if (!invocationMatch.Success) Fail("INVOCATION_ID");
        int attempt = Int32.Parse(invocationMatch.Groups["attempt"].Value, CultureInfo.InvariantCulture);
        if (!String.Equals(invocationMatch.Groups["action"].Value, invocationAction, StringComparison.Ordinal)) Fail("ACTION_MISMATCH");

        string logParent = Path.GetDirectoryName(logPath);
        if (!Directory.Exists(logParent)) Fail("LOG_PARENT");
        ValidateNoReparse(logParent, "LOG_REPARSE");
        if (File.Exists(logPath) || Directory.Exists(logPath)) Fail("LOG_EXISTS");
        string evidencePath = logPath + ".evidence.json";
        if (File.Exists(evidencePath) || Directory.Exists(evidencePath)) Fail("EVIDENCE_EXISTS");
        string logRelative = RelativeBelow(logPath, logRoot);
        string[] logParts = logRelative.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        if (logParts.Length != 3 || !String.Equals(logParts[2], "build.log", StringComparison.Ordinal)) Fail("LOG_SHAPE");
        if (!String.Equals(logParts[0], taskId, StringComparison.Ordinal)) Fail("TASK_MISMATCH");
        if (!String.Equals(logParts[1], invocationId, StringComparison.Ordinal)) Fail("INVOCATION_MISMATCH");

        context.TaskId = taskId;
        context.InvocationId = invocationId;
        context.Action = requestedAction;
        context.Attempt = attempt;
        context.FaultInjected = attempt == 0 && String.Equals(requestedAction, "Make", StringComparison.Ordinal);
        context.ProjectPath = projectPath;
        context.LogPath = logPath;

        string projectHash = ComputeSha256(projectPath);
        if (!String.Equals(projectHash, DemoAdapterConfiguration.ProjectSha256, StringComparison.Ordinal)) Fail("PROJECT_HASH");
        string projectText = ReadStrictCp932(projectPath);
        if (projectText.IndexOf(ProtocolMarker, StringComparison.Ordinal) < 0) Fail("PROJECT_PROTOCOL");
        if (Regex.IsMatch(projectText, "Microsoft Developer Studio (?:Project|Workspace) File", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) Fail("REAL_VC6_SIGNATURE");

        string vcxProjectPath = Path.ChangeExtension(projectPath, ".vcxproj");
        if (!File.Exists(vcxProjectPath)) Fail("VCXPROJECT_MISSING");
        ValidateNoReparse(vcxProjectPath, "PROJECT_REPARSE");
        string vcxHash = ComputeSha256(vcxProjectPath);
        if (!String.Equals(vcxHash, DemoAdapterConfiguration.VcxProjectSha256, StringComparison.Ordinal)) Fail("VCXPROJECT_HASH");
        context.VcxProjectPath = vcxProjectPath;
        context.ProjectSha256 = projectHash;
        context.VcxProjectSha256 = vcxHash;

        string msBuildPath = GetFullLocalPath(DemoAdapterConfiguration.MsBuildPath, "MSBUILD_PATH");
        if (!File.Exists(msBuildPath)) Fail("MSBUILD_MISSING");
        ValidateNoReparse(msBuildPath, "MSBUILD_REPARSE");
        string msBuildHash = ComputeSha256(msBuildPath);
        if (!String.Equals(msBuildHash, DemoAdapterConfiguration.MsBuildSha256, StringComparison.Ordinal)) Fail("MSBUILD_HASH");
        context.MsBuildSha256 = msBuildHash;

        string projectDirectory = Path.GetDirectoryName(projectPath);
        string safeUserRoot = Path.Combine(projectDirectory, ".team-bob-empty-user");
        if (File.Exists(safeUserRoot) || Directory.Exists(safeUserRoot)) Fail("UNSAFE_USER_PROPS");
        string artifactPath = Path.Combine(projectDirectory, "bin", "Release", "CycleWatchTests.exe");
        if (File.Exists(artifactPath) || Directory.Exists(artifactPath)) Fail("STALE_ARTIFACT");
        context.ArtifactPath = artifactPath;

        string adapterPath = typeof(DemoMsdevAdapter).Assembly.Location;
        ValidateNoReparse(adapterPath, "ADAPTER_REPARSE");
        context.AdapterSha256 = ComputeSha256(adapterPath);
    }

    private static int ExecuteBuild(DemoAdapterContext context)
    {
        string projectDirectory = Path.GetDirectoryName(context.ProjectPath);
        string safeUserRoot = Path.Combine(projectDirectory, ".team-bob-empty-user");
        string invocationRoot = Path.GetDirectoryName(Path.GetDirectoryName(projectDirectory));
        string safeNativeTemp = Path.Combine(invocationRoot, ".team-bob-native-temp");
        if (File.Exists(safeNativeTemp) || Directory.Exists(safeNativeTemp)) Fail("NATIVE_TEMP_EXISTS");
        ValidateNoReparse(invocationRoot, "NATIVE_TEMP_REPARSE");
        Directory.CreateDirectory(safeNativeTemp);
        ValidateNoReparse(safeNativeTemp, "NATIVE_TEMP_REPARSE");
        List<string> nativeArguments = new List<string>();
        nativeArguments.Add(context.VcxProjectPath);
        nativeArguments.Add(String.Equals(context.Action, "Make", StringComparison.Ordinal) ? "/t:Build" : "/t:Rebuild");
        nativeArguments.Add("/p:Configuration=Release");
        nativeArguments.Add("/p:Platform=Win32");
        nativeArguments.Add("/m:1");
        nativeArguments.Add("/nodeReuse:false");
        nativeArguments.Add("/noAutoResponse");
        nativeArguments.Add("/p:ImportDirectoryBuildProps=false");
        nativeArguments.Add("/p:ImportDirectoryBuildTargets=false");
        nativeArguments.Add("/p:UserRootDir=" + safeUserRoot);

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = DemoAdapterConfiguration.MsBuildPath;
        startInfo.Arguments = JoinArguments(nativeArguments);
        startInfo.WorkingDirectory = projectDirectory;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;
        SanitizeChildEnvironment(startInfo, context.FaultInjected, safeNativeTemp);

        Process process = new Process();
        process.StartInfo = startInfo;
        try
        {
            try
            {
                if (!process.Start()) Fail("MSBUILD_START");
            }
            catch (DemoAdapterFailureException) { throw; }
            catch (Exception) { Fail("MSBUILD_START"); }
            Task<byte[]> outputTask = ReadAllNativeBytesAsync(process.StandardOutput.BaseStream);
            Task<byte[]> errorTask = ReadAllNativeBytesAsync(process.StandardError.BaseStream);
            try
            {
                process.WaitForExit();
                Task.WaitAll(outputTask, errorTask);
            }
            catch (Exception) { Fail("MSBUILD_OUTPUT_READ"); }
            context.NativeExitCode = process.ExitCode;
            try { context.NativeOutput = CombineNativeOutput(DecodeNativeOutput(outputTask.Result), DecodeNativeOutput(errorTask.Result)); }
            catch (Exception) { Fail("MSBUILD_OUTPUT_ENCODING"); }
        }
        finally
        {
            process.Dispose();
        }

        if (context.NativeExitCode.GetValueOrDefault() != 0)
        {
            context.FinishedAt = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            if (!TryPublish(context, "FAILED", null, null)) return 20;
            return 1;
        }
        if (!File.Exists(context.ArtifactPath)) Fail("MISSING_ARTIFACT");
        ValidateNoReparse(context.ArtifactPath, "ARTIFACT_REPARSE");
        string artifactHash = ComputeSha256(context.ArtifactPath);
        context.FinishedAt = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        if (!TryPublish(context, "SUCCEEDED", null, artifactHash)) return 20;
        return 0;
    }

    private static int EmitEnvironmentFailure(DemoAdapterContext context, string reason)
    {
        context.FinishedAt = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        WriteEnvironmentError(reason);
        if (!String.IsNullOrEmpty(context.LogPath) && !File.Exists(context.LogPath) && !Directory.Exists(context.LogPath))
        {
            TryPublish(context, "ENVIRONMENT_ERROR", reason, null);
        }
        return 20;
    }

    private static bool TryPublish(DemoAdapterContext context, string status, string environmentError, string artifactHash)
    {
        string evidencePath = context.LogPath + ".evidence.json";
        string parent = Path.GetDirectoryName(context.LogPath);
        string token = Guid.NewGuid().ToString("N");
        string logTemporaryPath = Path.Combine(parent, ".build.log." + token + ".tmp");
        string evidenceTemporaryPath = Path.Combine(parent, ".build.log.evidence." + token + ".tmp");
        bool logTemporaryOwned = false;
        bool evidenceTemporaryOwned = false;
        bool evidencePublished = false;
        bool logPublished = false;
        string logHash = null;
        string evidenceHash = null;
        try
        {
            if (!Directory.Exists(parent)) throw new IOException("Log parent disappeared.");
            ValidateNoReparse(parent, "LOG_REPARSE");
            if (File.Exists(context.LogPath) || Directory.Exists(context.LogPath) || File.Exists(evidencePath) || Directory.Exists(evidencePath))
                throw new IOException("A final evidence path appeared before publication.");

            string logText = BuildLog(context, status, environmentError);
            byte[] logBytes = StrictCp932().GetBytes(logText);
            string evidenceText = BuildEvidenceJson(context, status, environmentError, artifactHash);
            byte[] evidenceBytes = new UTF8Encoding(false, true).GetBytes(evidenceText);

            logHash = ComputeSha256(logBytes);
            evidenceHash = ComputeSha256(evidenceBytes);
            WriteCreateNew(logTemporaryPath, logBytes, ref logTemporaryOwned);
            WriteCreateNew(evidenceTemporaryPath, evidenceBytes, ref evidenceTemporaryOwned);
            if (!String.Equals(ComputeSha256(logTemporaryPath), logHash, StringComparison.Ordinal) ||
                !String.Equals(ComputeSha256(evidenceTemporaryPath), evidenceHash, StringComparison.Ordinal))
                throw new IOException("Prepared evidence hash changed.");

            File.Move(evidenceTemporaryPath, evidencePath);
            evidenceTemporaryOwned = false;
            evidencePublished = true;
            File.Move(logTemporaryPath, context.LogPath);
            logTemporaryOwned = false;
            logPublished = true;
            return true;
        }
        catch (Exception)
        {
            if (!logPublished && evidencePublished) TryRemoveOwnedFile(evidencePath, parent, evidenceHash);
            if (evidenceTemporaryOwned) TryRemoveOwnedFile(evidenceTemporaryPath, parent, evidenceHash);
            if (logTemporaryOwned) TryRemoveOwnedFile(logTemporaryPath, parent, logHash);
            WriteEnvironmentError("EVIDENCE_WRITE");
            return false;
        }
    }

    private static void WriteEnvironmentError(string reason)
    {
        Console.Error.WriteLine(AsciiBanner);
        Console.Error.WriteLine("TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR=" + reason);
    }

    private static void WriteCreateNew(string path, byte[] bytes, ref bool owned)
    {
        using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            owned = true;
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }
    }

    private static bool TryRemoveOwnedFile(string path, string parent, string expectedHash)
    {
        try
        {
            if (String.IsNullOrEmpty(path) || String.IsNullOrEmpty(parent) || String.IsNullOrEmpty(expectedHash)) return false;
            string pathFull = Path.GetFullPath(path);
            string parentFull = Path.GetFullPath(parent).TrimEnd('\\', '/');
            if (!String.Equals(Path.GetDirectoryName(pathFull), parentFull, StringComparison.OrdinalIgnoreCase)) return false;
            ValidateNoReparse(parentFull, "EVIDENCE_REPARSE");
            if (Directory.Exists(pathFull)) return false;
            if (!File.Exists(pathFull)) return true;
            ValidateNoReparse(pathFull, "EVIDENCE_REPARSE");
            if (!String.Equals(ComputeSha256(pathFull), expectedHash, StringComparison.Ordinal)) return false;
            File.Delete(pathFull);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string BuildLog(DemoAdapterContext context, string status, string environmentError)
    {
        StringBuilder builder = new StringBuilder();
        AppendLogLine(builder, AsciiBanner);
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_SCHEMA=1.0");
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_TASK=" + ValueOrUnknown(context.TaskId));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_INVOCATION=" + ValueOrUnknown(context.InvocationId));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_ACTION=" + ValueOrUnknown(context.Action));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_ATTEMPT=" + (context.Attempt < 0 ? "unknown" : context.Attempt.ToString(CultureInfo.InvariantCulture)));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_FAULT_INJECTED=" + (context.FaultInjected ? "true" : "false"));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_ADAPTER_SHA256=" + ValueOrUnknown(context.AdapterSha256));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_MSBUILD_SHA256=" + ValueOrUnknown(context.MsBuildSha256));
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_NATIVE_EXIT=" + (context.NativeExitCode.HasValue ? context.NativeExitCode.Value.ToString(CultureInfo.InvariantCulture) : "not-started"));
        if (!String.IsNullOrEmpty(context.NativeOutput)) builder.Append(NormalizeCrLf(context.NativeOutput));
        if (!String.IsNullOrEmpty(environmentError)) AppendLogLine(builder, "TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR=" + environmentError);
        AppendLogLine(builder, "TEAM_BOB_ADAPTER_STATUS=" + status);
        return builder.ToString();
    }

    private static string BuildEvidenceJson(DemoAdapterContext context, string status, string environmentError, string artifactHash)
    {
        StringBuilder builder = new StringBuilder();
        builder.Append("{\r\n");
        AppendJsonString(builder, "schemaVersion", "1.0", true);
        AppendJsonString(builder, "banner", UnicodeBanner, true);
        AppendJsonString(builder, "taskId", context.TaskId, true);
        AppendJsonString(builder, "invocationId", context.InvocationId, true);
        AppendJsonString(builder, "action", context.Action, true);
        AppendJsonNumber(builder, "attempt", context.Attempt < 0 ? (int?)null : context.Attempt, true);
        AppendJsonBoolean(builder, "faultInjected", context.FaultInjected, true);
        AppendJsonString(builder, "adapterSha256", context.AdapterSha256, true);
        AppendJsonString(builder, "msBuildPath", DemoAdapterConfiguration.MsBuildPath, true);
        AppendJsonString(builder, "msBuildSha256", context.MsBuildSha256, true);
        AppendJsonString(builder, "sandboxRoot", DemoAdapterConfiguration.SandboxRoot, true);
        AppendJsonString(builder, "logRoot", DemoAdapterConfiguration.LogRoot, true);
        AppendJsonString(builder, "projectRelativePath", DemoAdapterConfiguration.ProjectRelativePath, true);
        AppendJsonString(builder, "projectSha256", context.ProjectSha256, true);
        AppendJsonString(builder, "vcxProjectSha256", context.VcxProjectSha256, true);
        AppendJsonString(builder, "target", DemoAdapterConfiguration.Target, true);
        AppendJsonString(builder, "expectedArtifactRelativePath", DemoAdapterConfiguration.ExpectedArtifactRelativePath, true);
        AppendJsonString(builder, "expectedArtifactSha256", artifactHash, true);
        AppendJsonNumber(builder, "nativeExitCode", context.NativeExitCode, true);
        AppendJsonString(builder, "startedAt", context.StartedAt, true);
        AppendJsonString(builder, "finishedAt", context.FinishedAt, true);
        AppendJsonString(builder, "status", status, true);
        AppendJsonString(builder, "environmentError", environmentError, false);
        builder.Append("}\r\n");
        return builder.ToString();
    }

    private static void SanitizeChildEnvironment(ProcessStartInfo startInfo, bool injectFault, string safeNativeTemp)
    {
        List<string> removals = new List<string>();
        foreach (string key in startInfo.EnvironmentVariables.Keys)
        {
            if (key.StartsWith("MSBUILD", StringComparison.OrdinalIgnoreCase) ||
                key.StartsWith("COR_", StringComparison.OrdinalIgnoreCase) ||
                key.StartsWith("CORECLR_", StringComparison.OrdinalIgnoreCase) ||
                key.StartsWith("COMPLUS_", StringComparison.OrdinalIgnoreCase) ||
                key.StartsWith("DOTNET_", StringComparison.OrdinalIgnoreCase)) removals.Add(key);
        }
        string[] fixedRemovals = new string[] {
            "CL", "_CL_", "LINK", "_LINK_", "VCTargetsPath", "VisualStudioVersion", "VSINSTALLDIR", "VCINSTALLDIR",
            "CLToolExe", "CLToolPath", "LinkToolExe", "LinkToolPath", "DirectoryBuildPropsPath", "DirectoryBuildTargetsPath",
            "CustomBeforeMicrosoftCppTargets", "CustomAfterMicrosoftCppTargets", "ForceImportBeforeCppTargets", "ForceImportAfterCppTargets",
            "PATH", "INCLUDE", "LIB", "LIBPATH", "TEMP", "TMP", "__COMPAT_LAYER"
        };
        removals.AddRange(fixedRemovals);
        foreach (string key in removals) startInfo.EnvironmentVariables.Remove(key);
        startInfo.EnvironmentVariables["PATH"] = Environment.SystemDirectory + ";" + Path.GetDirectoryName(Environment.SystemDirectory);
        startInfo.EnvironmentVariables["TEMP"] = safeNativeTemp;
        startInfo.EnvironmentVariables["TMP"] = safeNativeTemp;
        if (injectFault) startInfo.EnvironmentVariables["CL"] = "/DTEAM_BOB_DEMO_FAULT";
    }

    private static string GetFullLocalPath(string value, string reason)
    {
        if (String.IsNullOrWhiteSpace(value) || value.IndexOf('\0') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0 ||
            value.StartsWith("\\\\", StringComparison.Ordinal) || value.StartsWith("//", StringComparison.Ordinal) ||
            !Regex.IsMatch(value, "^[A-Za-z]:[\\\\/]", RegexOptions.CultureInvariant)) Fail(reason);
        string full;
        try { full = Path.GetFullPath(value).TrimEnd('\\', '/'); }
        catch (Exception) { Fail(reason); return null; }
        string root = Path.GetPathRoot(full);
        if (String.IsNullOrEmpty(root) || full.Equals(root.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase)) Fail(reason);
        try
        {
            DriveInfo drive = new DriveInfo(root);
            if (!drive.IsReady || drive.DriveType != DriveType.Fixed) Fail(reason);
        }
        catch (DemoAdapterFailureException) { throw; }
        catch (Exception) { Fail(reason); }
        return full;
    }

    private static string ValidateExistingRoot(string value, string reason)
    {
        string full = GetFullLocalPath(value, reason);
        if (!Directory.Exists(full)) Fail(reason);
        ValidateNoReparse(full, reason);
        return full;
    }

    private static void ValidateNoReparse(string path, string reason)
    {
        string full = Path.GetFullPath(path).TrimEnd('\\', '/');
        string root = Path.GetPathRoot(full);
        string current = root;
        string[] components = full.Substring(root.Length).Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string component in components)
        {
            current = Path.Combine(current, component);
            if (File.Exists(current) || Directory.Exists(current))
            {
                FileAttributes attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0) Fail(reason);
            }
        }
    }

    private static bool AtOrBelow(string path, string root)
    {
        return path.Equals(root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static bool StrictlyBelow(string path, string root)
    {
        return !path.Equals(root, StringComparison.OrdinalIgnoreCase) && path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string RelativeBelow(string path, string root)
    {
        return path.Substring(root.Length).TrimStart('\\', '/');
    }

    private static string ComputeSha256(string path)
    {
        using (SHA256 sha256 = SHA256.Create())
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            return BitConverter.ToString(sha256.ComputeHash(stream)).Replace("-", String.Empty).ToLowerInvariant();
        }
    }

    private static string ComputeSha256(byte[] bytes)
    {
        using (SHA256 sha256 = SHA256.Create())
        {
            return BitConverter.ToString(sha256.ComputeHash(bytes)).Replace("-", String.Empty).ToLowerInvariant();
        }
    }

    private static Encoding StrictCp932()
    {
        return Encoding.GetEncoding(932, new EncoderExceptionFallback(), new DecoderExceptionFallback());
    }

    private static async Task<byte[]> ReadAllNativeBytesAsync(Stream stream)
    {
        using (MemoryStream buffer = new MemoryStream())
        {
            byte[] block = new byte[8192];
            int read;
            while ((read = await stream.ReadAsync(block, 0, block.Length).ConfigureAwait(false)) > 0)
            {
                buffer.Write(block, 0, read);
            }
            return buffer.ToArray();
        }
    }

    private static string DecodeNativeOutput(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0) return String.Empty;
        int offset = bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
        try { return new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset); }
        catch (DecoderFallbackException) { return StrictCp932().GetString(bytes); }
    }

    private static string ReadStrictCp932(string path)
    {
        try { return StrictCp932().GetString(File.ReadAllBytes(path)); }
        catch (Exception) { Fail("PROJECT_ENCODING"); return null; }
    }

    private static string JoinArguments(IList<string> arguments)
    {
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < arguments.Count; index++)
        {
            if (index > 0) builder.Append(' ');
            builder.Append(QuoteArgument(arguments[index]));
        }
        return builder.ToString();
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return value;
        StringBuilder builder = new StringBuilder();
        builder.Append('"');
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"')
            {
                builder.Append('\\', slashes * 2 + 1);
                builder.Append('"');
                slashes = 0;
                continue;
            }
            builder.Append('\\', slashes);
            slashes = 0;
            builder.Append(character);
        }
        builder.Append('\\', slashes * 2);
        builder.Append('"');
        return builder.ToString();
    }

    private static string CombineNativeOutput(string standardOutput, string standardError)
    {
        StringBuilder builder = new StringBuilder();
        if (!String.IsNullOrEmpty(standardOutput)) builder.Append(NormalizeCrLf(standardOutput));
        if (!String.IsNullOrEmpty(standardError)) builder.Append(NormalizeCrLf(standardError));
        return builder.ToString();
    }

    private static string NormalizeCrLf(string value)
    {
        string normalized = value.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "\r\n");
        if (!normalized.EndsWith("\r\n", StringComparison.Ordinal)) normalized += "\r\n";
        return normalized;
    }

    private static void AppendLogLine(StringBuilder builder, string value) { builder.Append(value).Append("\r\n"); }
    private static string ValueOrUnknown(string value) { return String.IsNullOrEmpty(value) ? "unknown" : value; }

    private static void AppendJsonString(StringBuilder builder, string name, string value, bool comma)
    {
        builder.Append("  \"").Append(EscapeJson(name)).Append("\": ");
        if (value == null) builder.Append("null"); else builder.Append('"').Append(EscapeJson(value)).Append('"');
        builder.Append(comma ? ",\r\n" : "\r\n");
    }

    private static void AppendJsonNumber(StringBuilder builder, string name, int? value, bool comma)
    {
        builder.Append("  \"").Append(EscapeJson(name)).Append("\": ");
        if (value.HasValue) builder.Append(value.Value.ToString(CultureInfo.InvariantCulture)); else builder.Append("null");
        builder.Append(comma ? ",\r\n" : "\r\n");
    }

    private static void AppendJsonBoolean(StringBuilder builder, string name, bool value, bool comma)
    {
        builder.Append("  \"").Append(EscapeJson(name)).Append("\": ").Append(value ? "true" : "false");
        builder.Append(comma ? ",\r\n" : "\r\n");
    }

    private static string EscapeJson(string value)
    {
        StringBuilder builder = new StringBuilder();
        foreach (char character in value)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (character < 0x20) builder.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(character);
                    break;
            }
        }
        return builder.ToString();
    }

    private static void Fail(string reason) { throw new DemoAdapterFailureException(reason); }
}
