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

    // Hold-to-alert: 3 seconds hold on volume key → panic alert
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable longPressDownRunnable = null;
    private Runnable longPressUpRunnable = null;
    private static final long LONG_PRESS_MS = 3000;

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
