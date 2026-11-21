using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

public sealed class MusicPlayer : IDisposable
{
    public enum PlaybackState { Stopped, Waiting, Playing, BetweenRepeats, Finished, Failed, Fading }

    public sealed class Cue
    {
        public long Frame { get; private set; }
        public long? PhaseTicks { get; private set; }

        public Cue(long frame, long? phaseTicks)
        {
            Frame = frame;
            PhaseTicks = phaseTicks;
        }
    }

    private const int FadeFrames = BeatSchedule.SampleRate * 350 / 1000;
    private readonly ManualResetEvent cancel = new ManualResetEvent(false);
    private Thread worker;
    private volatile PlaybackState state;
    private volatile string error;
    private volatile bool loop;
    private volatile bool fade;
    private volatile bool capturePause;
    private volatile int volume = 100;
    private Cue pausedAt;
    private long previewPosition;

    public PlaybackState State { get { return state; } }
    public string Error { get { return error; } }
    public bool Loop { get { return loop; } set { loop = value; } }
    public int Volume { get { return volume; } set { volume = Math.Max(0, Math.Min(value, 100)); } }
    public bool IsFading { get { return fade && state != PlaybackState.Stopped && state != PlaybackState.Failed; } }
    // Source frames after the song's end describe progress through the repeat silence.
    public long PreviewPosition { get { return Interlocked.Read(ref previewPosition); } }

    // nextBeatTicks is a Stopwatch.GetTimestamp() reading on this machine.
    // Play, Stop and Dispose belong to the same controlling thread.
    public void Play(string path, BeatSchedule schedule, bool repeat, long nextBeatTicks, Cue cue)
    {
        Play(path, schedule, repeat, nextBeatTicks, cue, null);
    }

    public void PlayPreview(string path, BeatSchedule schedule, bool repeat, long position)
    {
        Play(path, schedule, repeat, null, null, position);
    }

    private void Play(string path, BeatSchedule schedule, bool repeat, long? nextBeatTicks,
        Cue cue, long? previewFrame)
    {
        Stop();
        Loop = repeat;
        Interlocked.Exchange(ref previewPosition, previewFrame.GetValueOrDefault());
        state = PlaybackState.Waiting;
        worker = new Thread(() =>
        {
            try
            {
                Render(path, schedule, nextBeatTicks, cue, previewFrame);
                if (!cancel.WaitOne(0))
                    state = fade ? PlaybackState.Stopped : PlaybackState.Finished;
            }
            catch (Exception failure)
            {
                error = failure.Message;
                state = PlaybackState.Failed;
            }
        });
        worker.IsBackground = true;
        worker.Start();
    }

    public Cue Pause()
    {
        pausedAt = null;
        capturePause = true;
        try
        {
            Stop();
            return pausedAt;
        }
        finally { capturePause = false; }
    }

    public void FadeOut()
    {
        if (IsFading)
            return;
        if (state == PlaybackState.Playing)
            fade = true;
        else
            Stop();
    }

    public void Stop()
    {
        cancel.Set();
        if (worker != null)
        {
            worker.Join();
            worker = null;
        }
        cancel.Reset();
        fade = false;
        error = null;
        state = PlaybackState.Stopped;
    }

    private void Render(string path, BeatSchedule schedule, long? nextBeatTicks,
        Cue cue, long? previewFrame)
    {
        double animationPeriod = schedule.Period;
        using (var song = new WaveFileReader(path))
        using (var enumerator = new MMDeviceEnumerator())
        using (var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
        using (var client = device.AudioClient)
        using (var ready = new AutoResetEvent(false))
        {
            WaveFormat format = song.WaveFormat;
            int frameBytes = format.BlockAlign;
            long duration = song.Length / frameBytes;
            if (format.Encoding != WaveFormatEncoding.Pcm || format.SampleRate != BeatSchedule.SampleRate ||
                format.Channels != 2 || format.BitsPerSample != 16 || schedule.DrumFrame >= duration)
                throw new InvalidOperationException("Invalid music asset or beat reference.");

            client.Initialize(AudioClientShareMode.Shared,
                AudioClientStreamFlags.EventCallback | AudioClientStreamFlags.AutoConvertPcm |
                AudioClientStreamFlags.SrcDefaultQuality, TimeSpan.FromMilliseconds(30).Ticks, 0, format, Guid.Empty);
            client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());
            var render = client.AudioRenderClient;
            var audioClock = client.AudioClockClient;
            double clockFrequency = audioClock.Frequency;
            // The endpoint can still be playing after the render buffer drains.
            double tailSeconds = Math.Max(0.1, TimeSpan.FromTicks(client.StreamLatency).TotalSeconds);
            int tailFrames = (int)Math.Ceiling(tailSeconds * format.SampleRate);
            int capacity = client.BufferSize;
            var buffer = new byte[capacity * frameBytes];
            var signals = new WaitHandle[] { cancel, ready };
            long written = 0;
            long previousEnd = 0;
            long previousStart = 0;
            long previousSourceFrame = 0;
            long initialFrame = Math.Max(0, previewFrame ?? (cue == null ? 0 : cue.Frame));
            bool inPreviewSilence = previewFrame.HasValue && Loop && initialFrame >= duration;
            long sourceFrame = inPreviewSilence ? 0 : Math.Min(initialFrame, duration - 1);
            song.Position = sourceFrame * frameBytes;
            long clipEnd = duration - sourceFrame;
            long? start = nextBeatTicks.HasValue ? (long?)null : 0;
            if (inPreviewSilence)
                start = Math.Max(0, schedule.PreviewRepeatFrame(duration, animationPeriod) - initialFrame);
            bool started = false;
            long? fadeStart = null;
            long fadeEnd = 0;
            try
            {
                while (!cancel.WaitOne(0))
                {
                    int padding = client.CurrentPadding;
                    long played = written - padding;
                    if (previewFrame.HasValue)
                    {
                        ulong position, qpc100ns;
                        long deviceFrame = started && audioClock.GetPosition(out position, out qpc100ns)
                            ? (long)(position / clockFrequency * format.SampleRate) : played;
                        UpdatePreviewPosition(deviceFrame, duration, initialFrame, previousEnd, start, sourceFrame);
                    }
                    int available = capacity - padding;
                    int frames = available;
                    bool silence = true;
                    if (fade && !fadeStart.HasValue)
                    {
                        fadeStart = written;
                        fadeEnd = start.HasValue && written >= start.Value
                            ? Math.Min(written + FadeFrames, start.Value + clipEnd)
                            : written;
                    }
                    if (!fadeStart.HasValue && start.HasValue && written == start.Value + clipEnd)
                    {
                        previousEnd = written;
                        previousStart = start.Value;
                        previousSourceFrame = sourceFrame;
                        sourceFrame = 0;
                        clipEnd = duration;
                        start = null;
                    }

                    if (fadeStart.HasValue)
                    {
                        state = PlaybackState.Fading;
                        silence = written >= fadeEnd;
                        long boundary = silence ? fadeEnd + tailFrames : fadeEnd;
                        frames = (int)Math.Min(frames, Math.Max(0, boundary - written));
                        if (frames == 0 && padding == 0)
                            return;
                    }
                    else if (previousEnd > 0 && !Loop && (!start.HasValue || written <= start.Value))
                    {
                        frames = (int)Math.Min(frames, Math.Max(0, previousEnd + tailFrames - written));
                        if (frames == 0 && padding == 0)
                            return;
                    }
                    else
                    {
                        if (!start.HasValue && previewFrame.HasValue)
                        {
                            long repeatFrame = schedule.PreviewRepeatFrame(duration, animationPeriod);
                            start = previousEnd + repeatFrame - duration;
                            song.Position = 0;
                        }
                        else if (!start.HasValue && started)
                        {
                            bool resuming = previousEnd == 0 && cue != null && cue.PhaseTicks.HasValue;
                            long earliest = Math.Max(written,
                                previousEnd == 0 ? 0 : schedule.AfterRepeatSilence(previousEnd));
                            ulong position, qpc100ns;
                            if (audioClock.GetPosition(out position, out qpc100ns) && position > 0)
                            {
                                long referenceTicks = resuming ? cue.PhaseTicks.Value : nextBeatTicks.Value;
                                double secondsUntilBeat = referenceTicks / (double)Stopwatch.Frequency -
                                    qpc100ns / 10000000.0;
                                double reference = (position / clockFrequency + secondsUntilBeat) * format.SampleRate;
                                // Leave at least one beat of silence after a complete play.
                                start = resuming ? schedule.ResumeFrame(reference, animationPeriod, earliest) :
                                    schedule.StartFrame(reference, animationPeriod, earliest);
                                song.Position = sourceFrame * frameBytes;
                            }
                        }

                        state = played < previousEnd || (start.HasValue && played >= start.Value)
                            ? PlaybackState.Playing
                            : previousEnd > 0 ? PlaybackState.BetweenRepeats : PlaybackState.Waiting;

                        silence = !start.HasValue || written < start.Value;
                        if (start.HasValue)
                        {
                            long boundary = silence ? start.Value : start.Value + clipEnd;
                            frames = (int)Math.Min(frames, boundary - written);
                        }
                    }

                    if (frames > 0)
                    {
                        int bytes = frames * frameBytes;
                        if (!silence && song.Read(buffer, 0, bytes) != bytes)
                            throw new InvalidOperationException("Music asset ended before its declared length.");
                        int level = Volume;
                        silence |= level == 0;
                        if (!silence && (level != 100 || fadeStart.HasValue))
                            ScaleSamples(buffer, frames, level, written, fadeStart, fadeEnd);
                        IntPtr destination = render.GetBuffer(frames);
                        if (!silence)
                            Marshal.Copy(buffer, 0, destination, bytes);
                        render.ReleaseBuffer(frames, silence ? AudioClientBufferFlags.Silent : AudioClientBufferFlags.None);
                        written += frames;
                    }

                    if (!started)
                    {
                        client.Start();
                        started = true;
                    }
                    // A song boundary can split one packet. Fill the remaining
                    // space now so the boundary cannot cause a buffer underrun.
                    if (frames > 0 && frames < available)
                        continue;
                    if (WaitHandle.WaitAny(signals, 2000) == WaitHandle.WaitTimeout)
                        throw new InvalidOperationException("Windows audio output stopped responding.");
                }
            }
            finally
            {
                if (started)
                {
                    client.Stop();
                    if (previewFrame.HasValue)
                    {
                        ulong position, qpc100ns;
                        long deviceFrame = audioClock.GetPosition(out position, out qpc100ns)
                            ? (long)(position / clockFrequency * format.SampleRate) : written - client.CurrentPadding;
                        UpdatePreviewPosition(deviceFrame, duration, initialFrame, previousEnd, start, sourceFrame);
                    }
                    else if (capturePause)
                    {
                        ulong position, qpc100ns;
                        bool haveClock = audioClock.GetPosition(out position, out qpc100ns);
                        double deviceFrame = haveClock ? position / clockFrequency * format.SampleRate :
                            written - client.CurrentPadding;
                        if (deviceFrame < previousEnd)
                        {
                            start = previousStart;
                            sourceFrame = previousSourceFrame;
                        }
                        if (start.HasValue)
                        {
                            long frame = Math.Max(start.Value, (long)Math.Floor(deviceFrame));
                            long songFrame = Math.Min(duration - 1, sourceFrame + frame - start.Value);
                            double seconds = (haveClock ? qpc100ns / 10000000.0 :
                                Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency) +
                                (frame - deviceFrame) / format.SampleRate;
                            pausedAt = new Cue(songFrame, (long)Math.Round(seconds * Stopwatch.Frequency));
                        }
                    }
                    client.Reset();
                }
            }
        }
    }

    private void UpdatePreviewPosition(long played, long duration, long initialFrame,
        long previousEnd, long? start, long sourceFrame)
    {
        long position;
        if (start.HasValue && played >= start.Value)
            position = sourceFrame + played - start.Value;
        else if (previousEnd > 0)
            position = duration + played - previousEnd;
        else
            position = initialFrame + played;
        Interlocked.Exchange(ref previewPosition, Loop ? position : Math.Min(duration, position));
    }

    private static void ScaleSamples(byte[] buffer, int frames, int volume, long written, long? fadeStart, long fadeEnd)
    {
        double volumeGain = volume / 100.0;
        for (int frame = 0; frame < frames; frame++)
        {
            double gain = fadeStart.HasValue ? volumeGain *
                (fadeEnd - written - frame - 1) / (fadeEnd - fadeStart.Value) : volumeGain;
            for (int channel = 0; channel < 2; channel++)
            {
                int offset = frame * 4 + channel * 2;
                short sample = (short)(buffer[offset] | buffer[offset + 1] << 8);
                short faded = (short)Math.Round(sample * gain);
                buffer[offset] = (byte)faded;
                buffer[offset + 1] = (byte)(faded >> 8);
            }
        }
    }

    public void Dispose()
    {
        Stop();
        cancel.Dispose();
    }
}
