using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using NAudio.Wave;

public static class MusicImport
{
    public const int MaxFrames = 60 * 60 * BeatSchedule.SampleRate;

    public static int Decode(string source, string destination)
    {
        if (String.Equals(Path.GetExtension(source), ".ncm", StringComparison.OrdinalIgnoreCase))
            return DecodeNcm(source, destination);
        return DecodeAudio(source, destination);
    }

    private static int DecodeNcm(string source, string destination)
    {
        using (var reader = new BinaryReader(File.OpenRead(source)))
        {
            byte[] mask = ReadNcmAudioMask(reader);
            var buffer = new byte[65536];
            int count = reader.Read(buffer, 0, buffer.Length);
            int offset = 0;
            UnmaskAudio(buffer, count, mask, ref offset);

            string extension = GetNcmAudioExtension(buffer, count);
            string extracted = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination)),
                Guid.NewGuid().ToString("N") + extension);
            var output = new FileStream(extracted, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            try
            {
                using (output)
                {
                    output.Write(buffer, 0, count);
                    while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        UnmaskAudio(buffer, count, mask, ref offset);
                        output.Write(buffer, 0, count);
                    }
                }
                return DecodeAudio(extracted, destination);
            }
            finally
            {
                File.Delete(extracted);
            }
        }
    }

    // NCM container layout and audio mask adapted from taurusxin/ncmdump.
    private static byte[] ReadNcmAudioMask(BinaryReader reader)
    {
        if (Encoding.ASCII.GetString(reader.ReadBytes(8)) != "CTENFDAM")
            throw new InvalidDataException("Invalid NCM header.");
        SkipNcmBytes(reader, 2);
        uint keyLength = reader.ReadUInt32();
        if (keyLength == 0 || keyLength % 16 != 0 || keyLength > 4096)
            throw new InvalidDataException("Invalid NCM audio key length.");
        byte[] encryptedKey = reader.ReadBytes((int)keyLength);
        if (encryptedKey.Length != keyLength)
            throw new EndOfStreamException("Incomplete NCM audio key.");
        for (int i = 0; i < encryptedKey.Length; i++)
            encryptedKey[i] ^= 0x64;

        byte[] key;
        using (var aes = Aes.Create())
        {
            aes.Mode = CipherMode.ECB;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = Encoding.ASCII.GetBytes("hzHRAmso5kInbaxW");
            using (var decryptor = aes.CreateDecryptor())
                key = decryptor.TransformFinalBlock(encryptedKey, 0, encryptedKey.Length);
        }
        const string prefix = "neteasecloudmusic";
        if (key.Length <= prefix.Length || Encoding.ASCII.GetString(key, 0, prefix.Length) != prefix)
            throw new InvalidDataException("Invalid NCM audio key.");

        uint metadataLength = reader.ReadUInt32();
        SkipNcmBytes(reader, metadataLength + 5L); // Metadata, CRC and image version.
        uint coverFrameLength = reader.ReadUInt32();
        uint coverLength = reader.ReadUInt32();
        if (coverLength > coverFrameLength)
            throw new InvalidDataException("Invalid NCM cover frame.");
        SkipNcmBytes(reader, coverFrameLength);

        var box = new byte[256];
        for (int i = 0; i < box.Length; i++)
            box[i] = (byte)i;
        int index = 0;
        int audioKeyLength = key.Length - prefix.Length;
        for (int i = 0; i < box.Length; i++)
        {
            byte value = box[i];
            index = (index + value + key[prefix.Length + i % audioKeyLength]) & 255;
            box[i] = box[index];
            box[index] = value;
        }

        var mask = new byte[256];
        for (int i = 0; i < mask.Length; i++)
        {
            int j = (i + 1) & 255;
            mask[i] = box[(box[j] + box[(box[j] + j) & 255]) & 255];
        }
        return mask;
    }

    private static void SkipNcmBytes(BinaryReader reader, long length)
    {
        Stream stream = reader.BaseStream;
        if (length > stream.Length - stream.Position)
            throw new EndOfStreamException("Incomplete NCM container.");
        stream.Seek(length, SeekOrigin.Current);
    }

    private static void UnmaskAudio(byte[] buffer, int count, byte[] mask, ref int offset)
    {
        for (int i = 0; i < count; i++)
            buffer[i] ^= mask[(offset + i) & 255];
        offset = (offset + count) & 255;
    }

    private static string GetNcmAudioExtension(byte[] buffer, int count)
    {
        if (count >= 4)
        {
            if (Encoding.ASCII.GetString(buffer, 0, 4) == "fLaC")
                return ".flac";
            if (Encoding.ASCII.GetString(buffer, 0, 3) == "ID3" ||
                (buffer[0] == 0xff && (buffer[1] & 0xe0) == 0xe0))
                return ".mp3";
        }
        throw new InvalidDataException("NCM audio is missing or is not MP3 or FLAC.");
    }

    private static int DecodeAudio(string source, string destination)
    {
        var format = new WaveFormat(BeatSchedule.SampleRate, 16, 2);
        using (var reader = new MediaFoundationReader(source))
        using (var resampler = new MediaFoundationResampler(reader, format))
        using (var writer = new WaveFileWriter(destination, format))
        {
            var buffer = new byte[format.AverageBytesPerSecond];
            int frames = 0;
            int count;
            while ((count = resampler.Read(buffer, 0, buffer.Length)) > 0)
            {
                frames += count / format.BlockAlign;
                if (frames > MaxFrames)
                    throw new InvalidDataException("Audio duration exceeds 60 minutes.");
                writer.Write(buffer, 0, count);
            }
            if (frames == 0)
                throw new InvalidDataException("The file contains no audio samples.");
            return frames;
        }
    }
}
