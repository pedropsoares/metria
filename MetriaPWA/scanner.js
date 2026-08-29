// Reads a QR code directly from the device camera, so pairing doesn't require leaving
// the PWA to use the system Camera app. Uses jsQR against a hidden canvas fed by a
// <video> element — no native BarcodeDetector dependency, since Safari support for it
// is inconsistent.
let activeStream;
let scanLoopHandle;

async function startQrScanner({ video, canvas, onDecode, onError }) {
  if (!navigator.mediaDevices?.getUserMedia) {
    onError("Camera access isn't available on this device or browser.");
    return;
  }

  try {
    activeStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
  } catch {
    onError("Camera access was denied. You can still type the phrase manually.");
    return;
  }

  video.srcObject = activeStream;
  await video.play();
  const context = canvas.getContext("2d", { willReadFrequently: true });

  const tick = () => {
    if (video.readyState === video.HAVE_ENOUGH_DATA) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      context.drawImage(video, 0, 0, canvas.width, canvas.height);
      const imageData = context.getImageData(0, 0, canvas.width, canvas.height);
      const code = jsQR(imageData.data, imageData.width, imageData.height);
      if (code?.data) {
        onDecode(code.data);
        return;
      }
    }
    scanLoopHandle = requestAnimationFrame(tick);
  };
  scanLoopHandle = requestAnimationFrame(tick);
}

function stopQrScanner() {
  if (scanLoopHandle) cancelAnimationFrame(scanLoopHandle);
  scanLoopHandle = null;
  activeStream?.getTracks().forEach((track) => track.stop());
  activeStream = null;
}

window.MetriaScanner = { startQrScanner, stopQrScanner };
