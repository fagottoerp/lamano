package com.dfa.flutterchatdemo;

import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;

public class MainActivity extends FlutterActivity {

    private static final String VOLUME_CHANNEL = "com.lamano.app/volume_keys";
    private EventChannel.EventSink eventSink = null;

    // Double-tap detection state
    private long lastVolumeDownTime = 0;
    private long lastVolumeUpTime = 0;
    private static final long DOUBLE_TAP_MS = 700;

    // Long-press detection state
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable longPressDownRunnable = null;
    private Runnable longPressUpRunnable = null;
    private static final long LONG_PRESS_MS = 1500;

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
    }

    private void sendEvent(String event) {
        if (eventSink != null) {
            new Handler(Looper.getMainLooper()).post(() -> eventSink.success(event));
        }
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            // Long press detection
            longPressDownRunnable = () -> sendEvent("long_down");
            handler.postDelayed(longPressDownRunnable, LONG_PRESS_MS);
            // Double-tap detection
            long now = System.currentTimeMillis();
            if (now - lastVolumeDownTime < DOUBLE_TAP_MS) {
                sendEvent("double_down");
                lastVolumeDownTime = 0;
            } else {
                lastVolumeDownTime = now;
            }
            return true; // consume key to prevent volume change
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            longPressUpRunnable = () -> sendEvent("long_up");
            handler.postDelayed(longPressUpRunnable, LONG_PRESS_MS);
            long now = System.currentTimeMillis();
            if (now - lastVolumeUpTime < DOUBLE_TAP_MS) {
                sendEvent("double_up");
                lastVolumeUpTime = 0;
            } else {
                lastVolumeUpTime = now;
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
