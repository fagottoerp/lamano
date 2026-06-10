package com.lamano2.com;

import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {

    private static final String VOLUME_CHANNEL = "com.lamano.app/volume_keys";
    private static final String SHARED_FILES_METHOD_CHANNEL = "com.lamano.app/shared_stickers";
    private static final String SHARED_FILES_EVENT_CHANNEL = "com.lamano.app/shared_stickers_events";
    private EventChannel.EventSink eventSink = null;
    private final ArrayList<String> pendingSharedFiles = new ArrayList<>();

    // Hold-to-alert: 3 seconds hold on volume key → panic alert
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable longPressDownRunnable = null;
    private Runnable longPressUpRunnable = null;
    private static final long LONG_PRESS_MS = 3000;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        captureSharedFiles(getIntent());
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new EventChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), VOLUME_CHANNEL)
            .setStreamHandler(new EventChannel.StreamHandler() {
                @Override
                public void onListen(Object args, EventChannel.EventSink sink) {
                    eventSink = sink;
                }
                @Override
                public void onCancel(Object args) {
                    eventSink = null;
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SHARED_FILES_METHOD_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("getInitialSharedFiles".equals(call.method)) {
                    ArrayList<String> files = new ArrayList<>(pendingSharedFiles);
                    pendingSharedFiles.clear();
                    result.success(files);
                } else {
                    result.notImplemented();
                }
            });

        new EventChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SHARED_FILES_EVENT_CHANNEL)
            .setStreamHandler(new EventChannel.StreamHandler() {
                @Override
                public void onListen(Object args, EventChannel.EventSink sink) {
                    eventSink = sink;
                    if (!pendingSharedFiles.isEmpty()) {
                        sink.success(new ArrayList<>(pendingSharedFiles));
                        pendingSharedFiles.clear();
                    }
                }

                @Override
                public void onCancel(Object args) {
                    eventSink = null;
                }
            });
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        captureSharedFiles(intent);
    }

    private void sendEvent(String event) {
        if (eventSink != null) {
            new Handler(Looper.getMainLooper()).post(() -> eventSink.success(event));
        }
    }

    private void sendSharedFiles(List<String> files) {
        if (files == null || files.isEmpty()) return;
        if (eventSink != null) {
            new Handler(Looper.getMainLooper()).post(() -> eventSink.success(new ArrayList<>(files)));
        } else {
            pendingSharedFiles.addAll(files);
        }
    }

    private void captureSharedFiles(Intent intent) {
        if (intent == null) return;

        String action = intent.getAction();
        if (action == null) return;

        ArrayList<String> files = new ArrayList<>();
        if (Intent.ACTION_SEND.equals(action)) {
            Uri uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (uri != null) {
                String path = copyUriToCache(uri);
                if (path != null) files.add(path);
            }
        } else if (Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            ArrayList<Uri> uris = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (uris != null) {
                for (Uri uri : uris) {
                    String path = copyUriToCache(uri);
                    if (path != null) files.add(path);
                }
            }
        }

        sendSharedFiles(files);
    }

    private String copyUriToCache(Uri uri) {
        try {
            InputStream inputStream = getContentResolver().openInputStream(uri);
            if (inputStream == null) return null;

            String fileName = "shared_" + System.currentTimeMillis();
            String mimeType = getContentResolver().getType(uri);
            if (mimeType != null) {
                if (mimeType.contains("zip")) fileName += ".zip";
                else if (mimeType.contains("webp")) fileName += ".webp";
                else if (mimeType.contains("png")) fileName += ".png";
                else if (mimeType.contains("jpeg") || mimeType.contains("jpg")) fileName += ".jpg";
                else if (mimeType.contains("gif")) fileName += ".gif";
                else fileName += ".bin";
            } else {
                fileName += ".bin";
            }

            File outFile = new File(getCacheDir(), fileName);
            FileOutputStream outputStream = new FileOutputStream(outFile);
            byte[] buffer = new byte[4096];
            int length;
            while ((length = inputStream.read(buffer)) > 0) {
                outputStream.write(buffer, 0, length);
            }
            outputStream.flush();
            outputStream.close();
            inputStream.close();
            return outFile.getAbsolutePath();
        } catch (Exception e) {
            return null;
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            // Only first press starts the timer (ignore auto-repeat from holding)
            if (event.getRepeatCount() == 0) {
                longPressDownRunnable = () -> sendEvent("long_down");
                handler.postDelayed(longPressDownRunnable, LONG_PRESS_MS);
            }
            return true; // consume key to prevent volume change
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (event.getRepeatCount() == 0) {
                longPressUpRunnable = () -> sendEvent("long_up");
                handler.postDelayed(longPressUpRunnable, LONG_PRESS_MS);
            }
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (longPressDownRunnable != null) {
                handler.removeCallbacks(longPressDownRunnable);
                longPressDownRunnable = null;
            }
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (longPressUpRunnable != null) {
                handler.removeCallbacks(longPressUpRunnable);
                longPressUpRunnable = null;
            }
            return true;
        }
        return super.onKeyUp(keyCode, event);
    }
}
