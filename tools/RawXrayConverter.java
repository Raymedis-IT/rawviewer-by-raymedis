import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/**
 * Converts headerless 16-bit little-endian detector frames to display-windowed
 * PNG and uncompressed Explicit-VR Little-Endian DICOM Secondary Capture files.
 */
public final class RawXrayConverter {
    // RxView loads corrected detector frames through RawImageLoader at 2500 x 3052.
    private static final int WIDTH = 2500;
    private static final int HEIGHT = 3052;
    private static final int HEADER_BYTES = 200;
    private static final long FRAME_BYTES = (long) WIDTH * HEIGHT * 2;
    private static final String SC_SOP_CLASS_UID = "1.2.840.10008.5.1.4.1.1.7";
    private static final String EXPLICIT_VR_LE_UID = "1.2.840.10008.1.2.1";
    private static final String UID_ROOT = "2.25.";

    private RawXrayConverter() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("Usage: RawXrayConverter <raw-input-folder>");
        }
        Path input = Path.of(args[0]);
        Path pngDirectory = input.resolve("png");
        Path dicomDirectory = input.resolve("dicom");
        Files.createDirectories(pngDirectory);
        Files.createDirectories(dicomDirectory);

        List<Path> rawFiles;
        try (var files = Files.list(input)) {
            rawFiles = files.filter(path -> path.getFileName().toString().endsWith(".raw"))
                    .sorted(Comparator.comparing(path -> path.getFileName().toString()))
                    .toList();
        }
        if (rawFiles.isEmpty()) throw new IllegalArgumentException("No .raw files found in " + input);

        String studyUid = newUid();
        String seriesUid = newUid();
        LocalDateTime now = LocalDateTime.now();
        int instanceNumber = 1;
        for (Path rawFile : rawFiles) {
            byte[] fileBytes = Files.readAllBytes(rawFile);
            if (fileBytes.length != HEADER_BYTES + FRAME_BYTES) {
                throw new IOException(rawFile.getFileName() + " is " + fileBytes.length
                        + " bytes; expected " + (HEADER_BYTES + FRAME_BYTES) + " bytes (a " + HEADER_BYTES
                        + "-byte detector header plus " + WIDTH + "x" + HEIGHT + " 16-bit pixels)");
            }
            byte[] pixels = java.util.Arrays.copyOfRange(fileBytes, HEADER_BYTES, fileBytes.length);
            String stem = rawFile.getFileName().toString().replaceFirst("\\.raw$", "");
            DisplayWindow displayWindow = displayWindow(pixels);
            writePng(pixels, pngDirectory.resolve(stem + ".png"), displayWindow);
            writeDicom(pixels, dicomDirectory.resolve(stem + ".dcm"), studyUid, seriesUid,
                    newUid(), instanceNumber++, now, rawFile.getFileName().toString(), displayWindow);
            System.out.println("Converted " + rawFile.getFileName());
        }
    }

    private static void writePng(byte[] littleEndianPixels, Path target, DisplayWindow displayWindow) throws IOException {
        short[] source = new short[WIDTH * HEIGHT];
        ByteBuffer.wrap(littleEndianPixels).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(source);

        BufferedImage image = new BufferedImage(WIDTH, HEIGHT, BufferedImage.TYPE_BYTE_GRAY);
        byte[] rendered = ((java.awt.image.DataBufferByte) image.getRaster().getDataBuffer()).getData();
        for (int index = 0; index < source.length; index++) {
            int value = Short.toUnsignedInt(source[index]);
            int scaled = (value - displayWindow.low()) * 255 / displayWindow.width();
            rendered[index] = (byte) Math.max(0, Math.min(255, scaled));
        }
        if (!ImageIO.write(image, "png", target.toFile())) {
            throw new IOException("No PNG writer is available");
        }
    }

    private static int percentile(int[] histogram, int total, double percentile) {
        int target = (int) Math.ceil(total * percentile);
        int cumulative = 0;
        for (int value = 0; value < histogram.length; value++) {
            cumulative += histogram[value];
            if (cumulative >= target) return value;
        }
        return histogram.length - 1;
    }

    private static DisplayWindow displayWindow(byte[] littleEndianPixels) {
        ByteBuffer data = ByteBuffer.wrap(littleEndianPixels).order(ByteOrder.LITTLE_ENDIAN);
        int[] histogram = new int[65536];
        while (data.hasRemaining()) histogram[Short.toUnsignedInt(data.getShort())]++;
        int low = percentile(histogram, WIDTH * HEIGHT, 0.01);
        int high = Math.max(low + 1, percentile(histogram, WIDTH * HEIGHT, 0.99));
        return new DisplayWindow(low, high);
    }

    private static void writeDicom(byte[] pixels, Path target, String studyUid, String seriesUid,
                                   String sopInstanceUid, int instanceNumber, LocalDateTime now,
                                   String sourceFile, DisplayWindow displayWindow) throws IOException {
        try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(target)))) {
            out.write(new byte[128]);
            out.write("DICM".getBytes(StandardCharsets.US_ASCII));
            List<byte[]> meta = new ArrayList<>();
            meta.add(element(0x0002, 0x0001, "OB", new byte[] {0, 1}));
            meta.add(element(0x0002, 0x0002, "UI", text(SC_SOP_CLASS_UID, true)));
            meta.add(element(0x0002, 0x0003, "UI", text(sopInstanceUid, true)));
            meta.add(element(0x0002, 0x0010, "UI", text(EXPLICIT_VR_LE_UID, true)));
            meta.add(element(0x0002, 0x0012, "UI", text("2.25.31088267500814112256176594341094131907", true)));
            meta.add(element(0x0002, 0x0013, "SH", text("RAYMEDIS_RAW_1", false)));
            int metaLength = meta.stream().mapToInt(bytes -> bytes.length).sum();
            out.write(element(0x0002, 0x0000, "UL", uint32(metaLength)));
            for (byte[] entry : meta) out.write(entry);

            String date = now.format(DateTimeFormatter.ofPattern("yyyyMMdd"));
            String time = now.format(DateTimeFormatter.ofPattern("HHmmss"));
            out.write(element(0x0008, 0x0016, "UI", text(SC_SOP_CLASS_UID, true)));
            out.write(element(0x0008, 0x0018, "UI", text(sopInstanceUid, true)));
            out.write(element(0x0008, 0x0020, "DA", text(date, false)));
            out.write(element(0x0008, 0x0023, "DA", text(date, false)));
            out.write(element(0x0008, 0x0030, "TM", text(time, false)));
            out.write(element(0x0008, 0x0033, "TM", text(time, false)));
            out.write(element(0x0008, 0x0060, "CS", text("OT", false)));
            out.write(element(0x0008, 0x0064, "CS", text("WSD", false)));
            out.write(element(0x0008, 0x0070, "LO", text("Raymedis RAW Viewer", false)));
            out.write(element(0x0008, 0x103E, "LO", text(sourceFile, false)));
            out.write(element(0x0010, 0x0010, "PN", text("Anonymous", false)));
            out.write(element(0x0010, 0x0020, "LO", text("RAW-EXPORT", false)));
            out.write(element(0x0020, 0x000D, "UI", text(studyUid, true)));
            out.write(element(0x0020, 0x000E, "UI", text(seriesUid, true)));
            out.write(element(0x0020, 0x0010, "SH", text("RAWEXPORT", false)));
            out.write(element(0x0020, 0x0011, "IS", text("1", false)));
            out.write(element(0x0020, 0x0013, "IS", text(Integer.toString(instanceNumber), false)));
            out.write(element(0x0028, 0x0002, "US", uint16(1)));
            out.write(element(0x0028, 0x0004, "CS", text("MONOCHROME2", false)));
            out.write(element(0x0028, 0x0010, "US", uint16(HEIGHT)));
            out.write(element(0x0028, 0x0011, "US", uint16(WIDTH)));
            out.write(element(0x0028, 0x0100, "US", uint16(16)));
            out.write(element(0x0028, 0x0101, "US", uint16(16)));
            out.write(element(0x0028, 0x0102, "US", uint16(15)));
            out.write(element(0x0028, 0x0103, "US", uint16(0)));
            out.write(element(0x0028, 0x1050, "DS", text(Integer.toString(displayWindow.center()), false)));
            out.write(element(0x0028, 0x1051, "DS", text(Integer.toString(displayWindow.width()), false)));
            out.write(element(0x7FE0, 0x0010, "OW", pixels));
        }
    }

    private static byte[] element(int group, int element, String vr, byte[] value) throws IOException {
        byte[] padded = pad(value, vr.equals("UI") ? (byte) 0 : (byte) ' ');
        boolean longVr = vr.equals("OB") || vr.equals("OW") || vr.equals("OF") || vr.equals("SQ")
                || vr.equals("UT") || vr.equals("UN") || vr.equals("UC") || vr.equals("UR");
        int headerLength = longVr ? 12 : 8;
        ByteBuffer buffer = ByteBuffer.allocate(headerLength + padded.length).order(ByteOrder.LITTLE_ENDIAN);
        buffer.putShort((short) group).putShort((short) element).put(vr.getBytes(StandardCharsets.US_ASCII));
        if (longVr) buffer.putShort((short) 0).putInt(padded.length); else buffer.putShort((short) padded.length);
        buffer.put(padded);
        return buffer.array();
    }

    private static byte[] pad(byte[] value, byte padByte) {
        if ((value.length & 1) == 0) return value;
        byte[] padded = new byte[value.length + 1];
        System.arraycopy(value, 0, padded, 0, value.length);
        padded[value.length] = padByte;
        return padded;
    }

    private static byte[] text(String value, boolean nullPad) {
        return pad(value.getBytes(StandardCharsets.US_ASCII), nullPad ? (byte) 0 : (byte) ' ');
    }

    private static byte[] uint16(int value) {
        return ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort((short) value).array();
    }

    private static byte[] uint32(long value) {
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt((int) value).array();
    }

    private static String newUid() {
        return UID_ROOT + new java.math.BigInteger(1, ByteBuffer.allocate(16)
                .putLong(UUID.randomUUID().getMostSignificantBits())
                .putLong(UUID.randomUUID().getLeastSignificantBits()).array());
    }

    private record DisplayWindow(int low, int high) {
        int width() { return high - low; }
        int center() { return low + width() / 2; }
    }
}
