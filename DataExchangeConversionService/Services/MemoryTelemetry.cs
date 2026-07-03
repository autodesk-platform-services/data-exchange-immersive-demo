using System.Diagnostics;

namespace DataExchangeViewingService.Services;

// TODO: temporary instrumentation for investigating the memory consumption of the extraction and
// conversion pipeline; remove once that investigation is done.
internal sealed class MemoryTelemetry(ILogger logger, string operation)
{
    public IDisposable Step(string stepName)
    {
        return new MemoryStep(logger, operation, stepName);
    }

    private sealed class MemoryStep : IDisposable
    {
        private readonly ILogger _logger;
        private readonly string _operation;
        private readonly string _stepName;
        private readonly Stopwatch _stopwatch;
        private readonly MemorySnapshot _before;
        private bool _disposed;

        public MemoryStep(ILogger logger, string operation, string stepName)
        {
            _logger = logger;
            _operation = operation;
            _stepName = stepName;
            _before = MemorySnapshot.Capture();
            _stopwatch = Stopwatch.StartNew();

            _logger.LogInformation(
                "Memory step started: {Operation} | {Step} | ManagedHeapMb={ManagedHeapMb:N2} | GcHeapMb={GcHeapMb:N2} | WorkingSetMb={WorkingSetMb:N2} | PrivateMemoryMb={PrivateMemoryMb:N2} | LohMb={LohMb:N2}",
                _operation,
                _stepName,
                ToMb(_before.ManagedHeapBytes),
                ToMb(_before.GcHeapBytes),
                ToMb(_before.WorkingSetBytes),
                ToMb(_before.PrivateMemoryBytes),
                ToMb(_before.LohBytes));
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

            _logger.LogInformation(
                "Memory step completed: {Operation} | {Step} | ElapsedMs={ElapsedMs:N0} | ManagedHeapBeforeMb={ManagedHeapBeforeMb:N2} | ManagedHeapAfterMb={ManagedHeapAfterMb:N2} | ManagedHeapDeltaMb={ManagedHeapDeltaMb:N2} | GcHeapAfterMb={GcHeapAfterMb:N2} | GcHeapDeltaMb={GcHeapDeltaMb:N2} | LohAfterMb={LohAfterMb:N2} | LohDeltaMb={LohDeltaMb:N2} | AllocatedDeltaMb={AllocatedDeltaMb:N2} | WorkingSetAfterMb={WorkingSetAfterMb:N2} | WorkingSetDeltaMb={WorkingSetDeltaMb:N2} | PrivateMemoryAfterMb={PrivateMemoryAfterMb:N2} | PrivateMemoryDeltaMb={PrivateMemoryDeltaMb:N2} | FragmentedAfterMb={FragmentedAfterMb:N2} | Gen0Collections={Gen0Collections} | Gen1Collections={Gen1Collections} | Gen2Collections={Gen2Collections}",
                _operation,
                _stepName,
                _stopwatch.Elapsed.TotalMilliseconds,
                ToMb(_before.ManagedHeapBytes),
                ToMb(after.ManagedHeapBytes),
                ToMb(after.ManagedHeapBytes - _before.ManagedHeapBytes),
                ToMb(after.GcHeapBytes),
                ToMb(after.GcHeapBytes - _before.GcHeapBytes),
                ToMb(after.LohBytes),
                ToMb(after.LohBytes - _before.LohBytes),
                ToMb(after.AllocatedBytes - _before.AllocatedBytes),
                ToMb(after.WorkingSetBytes),
                ToMb(after.WorkingSetBytes - _before.WorkingSetBytes),
                ToMb(after.PrivateMemoryBytes),
                ToMb(after.PrivateMemoryBytes - _before.PrivateMemoryBytes),
                ToMb(after.FragmentedBytes),
                after.Gen0Collections - _before.Gen0Collections,
                after.Gen1Collections - _before.Gen1Collections,
                after.Gen2Collections - _before.Gen2Collections);
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
