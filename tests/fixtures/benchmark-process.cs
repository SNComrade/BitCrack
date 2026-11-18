using System;
using System.IO;
using System.Threading;

internal static class BenchmarkProcess
{
    private static int Main(string[] args)
    {
        string executable = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (executable == "nvidia-smi")
        {
            if (Array.IndexOf(args, "--query-gpu=uuid,name,driver_version") >= 0)
            {
                Console.WriteLine("GPU-chosen, NVIDIA Fixture Chosen, 123.45");
                Console.WriteLine("GPU-other, NVIDIA Fixture Other, 123.45");
                if (Environment.GetEnvironmentVariable("BITCRACK_TEST_DUPLICATE_GPU") == "1")
                    Console.WriteLine("GPU-duplicate, NVIDIA Fixture Chosen, 123.45");
                return 0;
            }

            int selector = Array.IndexOf(args, "-i");
            if (selector < 0 || args[selector + 1] == "GPU-chosen")
                Console.WriteLine("80, 1024, 60, 100.5, 1800");
            if (selector < 0 || args[selector + 1] == "GPU-other")
                Console.WriteLine("100, 8192, 95, 200, 2100");
            Console.Out.Flush();
            using (var ready = EventWaitHandle.OpenExisting(Environment.GetEnvironmentVariable("BITCRACK_TEST_TELEMETRY_READY")))
                ready.Set();
            return 0;
        }

        if (Array.IndexOf(args, "--list-devices") >= 0)
        {
            Console.WriteLine("ID:     0\nName:   NVIDIA Fixture Other\n");
            Console.WriteLine("ID:     1\nName:   NVIDIA Fixture Chosen");
            return 0;
        }

        if (Environment.GetEnvironmentVariable("BITCRACK_TEST_DUPLICATE_GPU") != "1")
        {
            using (var ready = EventWaitHandle.OpenExisting(Environment.GetEnvironmentVariable("BITCRACK_TEST_TELEMETRY_READY")))
            {
                if (!ready.WaitOne(TimeSpan.FromSeconds(5)))
                {
                    Console.Error.WriteLine("Error: telemetry fixture never produced a sample");
                    return 8;
                }
            }
        }
        if (Array.IndexOf(args, "--help") >= 0)
            return 0;

        Console.WriteLine("123.4 MKey/s");
        if (Array.IndexOf(args, "31") >= 0)
        {
            Console.Out.Flush();
            Thread.Sleep(Timeout.Infinite);
        }
        if (Array.IndexOf(args, "13") >= 0)
        {
            Console.Error.WriteLine("Error: deliberate fixture failure");
            return 7;
        }

        Console.Error.WriteLine("Fixture completed.");
        return 0;
    }
}
