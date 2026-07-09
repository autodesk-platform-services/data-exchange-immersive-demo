using System.Diagnostics;
using System.Globalization;

namespace DataExchangeConversionService.Services;

// TODO: temporary instrumentation for investigating the memory consumption of the extraction and
// conversion pipeline; remove once that investigation is done.
internal sealed class MemoryTelemetry(ILogger logger, string operation, string? logPath = null)
{
    public IDisposable Step(string stepName)
    {
        return new MemoryStep(logger, operation, stepName, logPath);
    }

    private sealed class MemoryStep : IDisposable
    {
        private readonly ILogger _logger;
        private readonly string _operation;
        private readonly string _stepName;
        private readonly string? _logPath;
        private readonly Stopwatch _stopwatch;
        private readonly MemorySnapshot _before;
        private bool _disposed;

        public MemoryStep(ILogger logger, string operation, string stepName, string? logPath)
        {
            _logger = logger;
            _operation = operation;
            _stepName = stepName;
            _logPath = logPath;
            _before = MemorySnapshot.Capture();
            _stopwatch = Stopwatch.StartNew();

            var managedHeapMb = ToMb(_before.ManagedHeapBytes);
            var gcHeapMb = ToMb(_before.GcHeapBytes);
            var workingSetMb = ToMb(_before.WorkingSetBytes);
            var privateMemoryMb = ToMb(_before.PrivateMemoryBytes);
            var lohMb = ToMb(_before.LohBytes);

            _logger.LogInformation(
                "Memory step started: {Operation} | {Step} | ManagedHeapMb={ManagedHeapMb:N2} | GcHeapMb={GcHeapMb:N2} | WorkingSetMb={WorkingSetMb:N2} | PrivateMemoryMb={PrivateMemoryMb:N2} | LohMb={LohMb:N2}",
                _operation,
                _stepName,
                managedHeapMb,
                gcHeapMb,
                workingSetMb,
                privateMemoryMb,
                lohMb);

            AppendToLogFile(
                $"Memory step started: {_operation} | {_stepName} | ManagedHeapMb={managedHeapMb:N2} | GcHeapMb={gcHeapMb:N2} | WorkingSetMb={workingSetMb:N2} | PrivateMemoryMb={privateMemoryMb:N2} | LohMb={lohMb:N2}");
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _stopwatch.Stop();
            var after = MemorySnapshot.Capture();

            var elapsedMs = _stopwatch.Elapsed.TotalMilliseconds;
            var managedHeapBeforeMb = ToMb(_before.ManagedHeapBytes);
            var managedHeapAfterMb = ToMb(after.ManagedHeapBytes);
            var managedHeapDeltaMb = ToMb(after.ManagedHeapBytes - _before.ManagedHeapBytes);
            var gcHeapAfterMb = ToMb(after.GcHeapBytes);
            var gcHeapDeltaMb = ToMb(after.GcHeapBytes - _before.GcHeapBytes);
            var lohAfterMb = ToMb(after.LohBytes);
            var lohDeltaMb = ToMb(after.LohBytes - _before.LohBytes);
            var allocatedDeltaMb = ToMb(after.AllocatedBytes - _before.AllocatedBytes);
            var workingSetAfterMb = ToMb(after.WorkingSetBytes);
            var workingSetDeltaMb = ToMb(after.WorkingSetBytes - _before.WorkingSetBytes);
            var privateMemoryAfterMb = ToMb(after.PrivateMemoryBytes);
            var privateMemoryDeltaMb = ToMb(after.PrivateMemoryBytes - _before.PrivateMemoryBytes);
            var fragmentedAfterMb = ToMb(after.FragmentedBytes);
            var gen0Collections = after.Gen0Collections - _before.Gen0Collections;
            var gen1Collections = after.Gen1Collections - _before.Gen1Collections;
            var gen2Collections = after.Gen2Collections - _before.Gen2Collections;

            _logger.LogInformation(
                "Memory step completed: {Operation} | {Step} | ElapsedMs={ElapsedMs:N0} | ManagedHeapBeforeMb={ManagedHeapBeforeMb:N2} | ManagedHeapAfterMb={ManagedHeapAfterMb:N2} | ManagedHeapDeltaMb={ManagedHeapDeltaMb:N2} | GcHeapAfterMb={GcHeapAfterMb:N2} | GcHeapDeltaMb={GcHeapDeltaMb:N2} | LohAfterMb={LohAfterMb:N2} | LohDeltaMb={LohDeltaMb:N2} | AllocatedDeltaMb={AllocatedDeltaMb:N2} | WorkingSetAfterMb={WorkingSetAfterMb:N2} | WorkingSetDeltaMb={WorkingSetDeltaMb:N2} | PrivateMemoryAfterMb={PrivateMemoryAfterMb:N2} | PrivateMemoryDeltaMb={PrivateMemoryDeltaMb:N2} | FragmentedAfterMb={FragmentedAfterMb:N2} | Gen0Collections={Gen0Collections} | Gen1Collections={Gen1Collections} | Gen2Collections={Gen2Collections}",
                _operation,
                _stepName,
                elapsedMs,
                managedHeapBeforeMb,
                managedHeapAfterMb,
                managedHeapDeltaMb,
                gcHeapAfterMb,
                gcHeapDeltaMb,
                lohAfterMb,
                lohDeltaMb,
                allocatedDeltaMb,
                workingSetAfterMb,
                workingSetDeltaMb,
                privateMemoryAfterMb,
                privateMemoryDeltaMb,
                fragmentedAfterMb,
                gen0Collections,
                gen1Collections,
                gen2Collections);

            AppendToLogFile(
                $"Memory step completed: {_operation} | {_stepName} | ElapsedMs={elapsedMs:N0} | ManagedHeapBeforeMb={managedHeapBeforeMb:N2} | ManagedHeapAfterMb={managedHeapAfterMb:N2} | ManagedHeapDeltaMb={managedHeapDeltaMb:N2} | GcHeapAfterMb={gcHeapAfterMb:N2} | GcHeapDeltaMb={gcHeapDeltaMb:N2} | LohAfterMb={lohAfterMb:N2} | LohDeltaMb={lohDeltaMb:N2} | AllocatedDeltaMb={allocatedDeltaMb:N2} | WorkingSetAfterMb={workingSetAfterMb:N2} | WorkingSetDeltaMb={workingSetDeltaMb:N2} | PrivateMemoryAfterMb={privateMemoryAfterMb:N2} | PrivateMemoryDeltaMb={privateMemoryDeltaMb:N2} | FragmentedAfterMb={fragmentedAfterMb:N2} | Gen0Collections={gen0Collections} | Gen1Collections={gen1Collections} | Gen2Collections={gen2Collections}");
        }

        private void AppendToLogFile(string message)
        {
            if (string.IsNullOrWhiteSpace(_logPath))
            {
                return;
            }

            File.AppendAllText(_logPath, string.Create(CultureInfo.CurrentCulture, $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}"));
        }
    }

    private sealed record MemorySnapshot(
        long ManagedHeapBytes,
        long AllocatedBytes,
        long GcHeapBytes,
        long LohBytes,
        long FragmentedBytes,
        long WorkingSetBytes,
        long PrivateMemoryBytes,
        int Gen0Collections,
        int Gen1Collections,
        int Gen2Collections)
    {
        public static MemorySnapshot Capture()
        {
            var process = Process.GetCurrentProcess();
            var gcInfo = GC.GetGCMemoryInfo();
            var generationInfo = gcInfo.GenerationInfo;

            return new MemorySnapshot(
                GC.GetTotalMemory(forceFullCollection: false),
                GC.GetTotalAllocatedBytes(precise: false),
                gcInfo.HeapSizeBytes,
                GetGenerationSize(generationInfo, 3),
                gcInfo.FragmentedBytes,
                process.WorkingSet64,
                process.PrivateMemorySize64,
                GC.CollectionCount(0),
                GC.CollectionCount(1),
                GC.CollectionCount(2));
        }

        private static long GetGenerationSize(ReadOnlySpan<GCGenerationInfo> generationInfo, int index)
        {
            return index < generationInfo.Length ? generationInfo[index].SizeAfterBytes : 0;
        }
    }

    private static double ToMb(long bytes) => bytes / 1024d / 1024d;
}
