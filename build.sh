#!/bin/bash

set -e

rm -rf app
mkdir -p app
cp -rf config.xml network_security_config.xml app
# Página do APK = o CARREGADOR (index-apk.html), que baixa o app do GitHub,
# injeta o cordova.js (ponte com o Android: RAM, player nativo, PiP...) e
# cuida da atualização automática. Se o index.html do app fosse direto pro
# APK, ele rodaria SEM a ponte com o Android e sem atualizar sozinho.
if [ -f index-apk.html ]; then
  cp index-apk.html app/index.html
  echo "📄 Página do APK: index-apk.html (carregador)."
else
  cp index.html app/index.html
  echo "⚠️  index-apk.html não encontrado — usando index.html."
fi
if grep -q "APP_VERSION" app/index.html; then
  echo "⚠️  ATENÇÃO: a página do APK é o app inteiro (não o carregador)."
  echo "    Sem o carregador o APK não terá ponte com o Android nem atualização automática."
  echo "    Coloque o carregador como index-apk.html nesta pasta."
fi

# ----------------------------------------------------------------------
# Plugin de PiP nativo: os arquivos ficam AQUI DENTRO do build.sh (não
# precisa mais baixar/extrair zip nenhum). Ele é recriado a cada build.
# ----------------------------------------------------------------------
PIP=app/cordova-plugin-manager-pip
mkdir -p "$PIP/src/android"
cat > "$PIP/package.json" <<'PIPEOF'
{
  "name": "cordova-plugin-manager-pip",
  "version": "1.0.0",
  "description": "Picture-in-Picture nativo do Android para o APK do Manager",
  "cordova": {
    "id": "cordova-plugin-manager-pip",
    "platforms": ["android"]
  },
  "keywords": ["ecosystem:cordova", "cordova-android"],
  "license": "MIT"
}
PIPEOF
cat > "$PIP/plugin.xml" <<'PIPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- PiP nativo do Android pro APK do Manager. O WebView não tem o
     Picture-in-Picture da web, então o botão de PiP chama este plugin, que
     coloca o app inteiro na janelinha flutuante do Android (8.0+). -->
<plugin xmlns="http://apache.org/cordova/ns/plugins/1.0"
        xmlns:android="http://schemas.android.com/apk/res/android"
        id="cordova-plugin-manager-pip" version="1.0.0">
  <name>ManagerPip</name>
  <platform name="android">
    <config-file target="res/xml/config.xml" parent="/*">
      <feature name="ManagerPip">
        <param name="android-package" value="com.manager.pip.ManagerPip" />
      </feature>
    </config-file>
    <edit-config file="AndroidManifest.xml" target="/manifest/application/activity[@android:name='MainActivity']" mode="merge">
      <activity android:supportsPictureInPicture="true" android:resizeableActivity="true" />
    </edit-config>
    <source-file src="src/android/ManagerPip.java" target-dir="src/com/manager/pip" />
  </platform>
</plugin>
PIPEOF
cat > "$PIP/src/android/ManagerPip.java" <<'PIPEOF'
package com.manager.pip;

import android.annotation.TargetApi;
import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.os.Debug;
import android.app.PictureInPictureParams;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Rational;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;

import android.app.Dialog;
import android.graphics.Color;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.content.DialogInterface;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.VideoView;
import android.view.ViewGroup;
import org.apache.cordova.PluginResult;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class ManagerPip extends CordovaPlugin {

    @Override
    public boolean execute(String action, JSONArray args, final CallbackContext callback) throws JSONException {
        // ---------- MINI PLAYER NATIVO (quadro do Ao Vivo, por cima do app) ----------
        // Um VideoView do Android posicionado em cima do quadro da página. Não
        // pega foco: as setas continuam navegando no app.
        if ("miniShow".equals(action) || "miniMove".equals(action)) {
            final boolean show = "miniShow".equals(action);
            final String url = show ? args.getString(0) : null;
            final int off = show ? 1 : 0;
            final int x = args.optInt(off), y = args.optInt(off + 1), w = args.optInt(off + 2), h = args.optInt(off + 3);
            final boolean visible = args.optBoolean(off + 4, true);
            final String bg = show ? args.optString(off + 5, "#0B0D16") : null;
            if (show) mCb = callback;
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (show) miniOpen(url, bg);
                        miniPlace(x, y, w, h, visible);
                        if (!show) callback.success();
                    } catch (Throwable t) { callback.error(t.getClass().getSimpleName() + ": " + t.getMessage()); }
                }
            });
            return true;
        }
        if ("miniHide".equals(action)) {
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() { miniClose("hidden"); callback.success(); }
            });
            return true;
        }
        // ---------- PLAYER NATIVO (tela cheia, fora do WebView) ----------
        // O Android toca o stream sozinho (TS ou HLS, com o chip de vídeo) —
        // sem JavaScript convertendo o vídeo. Voltar fecha e devolve pro app.
        if ("hasNativePlayer".equals(action)) {
            callback.success(1);
            return true;
        }
        if ("playVideo".equals(action)) {
            final String url = args.getString(0);
            final String title = args.optString(1, "");
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try { openPlayer(url, title, callback); }
                    catch (Throwable t) { callback.error(t.getClass().getSimpleName() + ": " + t.getMessage()); }
                }
            });
            return true;
        }
        if ("stopVideo".equals(action)) {
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() { closePlayer("stopped"); callback.success(); }
            });
            return true;
        }
        if ("isSupported".equals(action)) {
            callback.success(isSupported() ? 1 : 0);
            return true;
        }
        if ("enter".equals(action)) {
            final int w = args.optInt(0, 16);
            final int h = args.optInt(1, 9);
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        if (!isSupported()) {
                            callback.error("PiP nao suportado neste aparelho (precisa Android 8.0+ com PiP liberado)");
                            return;
                        }
                        if (enterPip(w, h)) callback.success();
                        else callback.error("O Android recusou o PiP (confira se o PiP esta permitido pro app nas configuracoes)");
                    } catch (Throwable t) {
                        callback.error(t.getClass().getSimpleName() + ": " + t.getMessage());
                    }
                }
            });
            return true;
        }
        // Limpa o cache HTTP do WebView (arquivos baixados da internet que o
        // navegador interno guarda). Não mexe em IndexedDB/localStorage.
        if ("clearCache".equals(action)) {
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        android.view.View v = webView.getView();
                        if (v instanceof android.webkit.WebView) ((android.webkit.WebView) v).clearCache(true);
                        else webView.clearCache();
                        callback.success();
                    } catch (Throwable t) {
                        callback.error(t.getClass().getSimpleName() + ": " + t.getMessage());
                    }
                }
            });
            return true;
        }
        // Memória RAM do aparelho (pro painel de diagnóstico do app):
        // total, livre, se o Android está em "pouca memória" e quanto este
        // app (processo principal) está usando.
        if ("memInfo".equals(action)) {
            // Roda FORA da thread da ponte JS<->Java: Debug.getMemoryInfo é
            // lento (centenas de ms num aparelho fraco) e, na thread da ponte,
            // travava a página inteira a cada leitura.
            cordova.getThreadPool().execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        ActivityManager am = (ActivityManager) cordova.getActivity().getSystemService(Context.ACTIVITY_SERVICE);
                        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
                        am.getMemoryInfo(mi);
                        JSONObject o = new JSONObject();
                        o.put("total", mi.totalMem);
                        o.put("avail", mi.availMem);
                        o.put("low", mi.lowMemory);
                        o.put("threshold", mi.threshold);
                        Debug.MemoryInfo dm = new Debug.MemoryInfo();
                        Debug.getMemoryInfo(dm);
                        o.put("appPssKb", dm.getTotalPss());
                        callback.success(o);
                    } catch (Throwable t) {
                        callback.error(t.getClass().getSimpleName() + ": " + t.getMessage());
                    }
                }
            });
            return true;
        }
        // Tela cheia de verdade no APK: esconde barra de status e de navegação
        // (o requestFullscreen do WebView sozinho não esconde a barra de status).
        if ("immersive".equals(action) || "showSystemUI".equals(action)) {
            final boolean on = "immersive".equals(action);
            cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    try {
                        setImmersive(on);
                        callback.success();
                    } catch (Throwable t) {
                        callback.error(t.getClass().getSimpleName() + ": " + t.getMessage());
                    }
                }
            });
            return true;
        }
        return false;
    }

    @SuppressWarnings("deprecation")
    private void setImmersive(boolean on) {
        Window w = cordova.getActivity().getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            setImmersiveApi30(w, on);
            return;
        }
        View d = w.getDecorView();
        if (on) {
            d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
        } else {
            d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);
        }
    }

    @TargetApi(30)
    private void setImmersiveApi30(Window w, boolean on) {
        WindowInsetsController c = w.getInsetsController();
        if (c == null) return;
        int bars = WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars();
        if (on) {
            c.hide(bars);
            // puxar da borda mostra as barras só por um instante
            c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        } else {
            c.show(bars);
        }
    }

    private boolean isSupported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;
        return cordova.getActivity().getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE);
    }

    @TargetApi(Build.VERSION_CODES.O)
    private boolean enterPip(int w, int h) {
        Activity activity = cordova.getActivity();
        w = Math.max(1, w);
        h = Math.max(1, h);
        // O Android só aceita proporções entre 1:2.39 e 2.39:1.
        float ratio = (float) w / (float) h;
        Rational r;
        if (ratio > 2.39f) r = new Rational(239, 100);
        else if (ratio < 1f / 2.39f) r = new Rational(100, 239);
        else r = new Rational(w, h);
        PictureInPictureParams params = new PictureInPictureParams.Builder().setAspectRatio(r).build();
        return activity.enterPictureInPictureMode(params);
    }

    // ================== PLAYER NATIVO ==================
    private Dialog pDialog;
    private VideoView pView;
    private TextView pLabel;
    private CallbackContext pCb;
    private final Handler pH = new Handler(Looper.getMainLooper());
    private int pRetries = 0;
    private boolean pEverPlayed = false;
    private int pLastPos = -1;
    private long pLastMove = 0;
    private String pUrl, pTitle;
    private Runnable pWatch, pHideLabel;

    private void pSend(String json, boolean keep) {
        if (pCb == null) return;
        PluginResult r = new PluginResult(PluginResult.Status.OK, json);
        r.setKeepCallback(keep);
        pCb.sendPluginResult(r);
        if (!keep) pCb = null;
    }
    private static String q(String s) { return JSONObject.quote(s == null ? "" : s); }

    private void pLabel(String text, boolean autoHide) {
        if (pLabel == null) return;
        pLabel.setText(text);
        pLabel.setVisibility(View.VISIBLE);
        if (pHideLabel != null) pH.removeCallbacks(pHideLabel);
        if (autoHide) {
            pHideLabel = new Runnable() { public void run() { if (pLabel != null) pLabel.setVisibility(View.GONE); } };
            pH.postDelayed(pHideLabel, 4000);
        }
    }

    private void openPlayer(String url, String title, CallbackContext cb) {
        closePlayer("replaced");
        miniClose("fullscreen"); // libera o decodificador pro vídeo em tela cheia
        pCb = cb; pUrl = url; pTitle = title; pRetries = 0; pEverPlayed = false; pLastPos = -1; pLastMove = System.currentTimeMillis();
        Activity act = cordova.getActivity();
        final Dialog d = new Dialog(act, android.R.style.Theme_Black_NoTitleBar_Fullscreen);
        FrameLayout root = new FrameLayout(act);
        root.setBackgroundColor(Color.BLACK);
        final VideoView v = new VideoView(act);
        root.addView(v, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        TextView t = new TextView(act);
        t.setTextColor(Color.WHITE); t.setTextSize(18); t.setPadding(36, 22, 36, 22);
        t.setBackgroundColor(0xAA000000);
        FrameLayout.LayoutParams tl = new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.LEFT);
        tl.setMargins(30, 30, 30, 30);
        root.addView(t, tl);
        d.setContentView(root);
        pDialog = d; pView = v; pLabel = t;
        pLabel(title + "  •  carregando...", false);

        v.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
            public void onPrepared(MediaPlayer mp) {
                pEverPlayed = true; pRetries = 0; pLastMove = System.currentTimeMillis();
                pLabel(pTitle, true);
                mp.start();
                pSend("{\"event\":\"playing\"}", true);
            }
        });
        v.setOnInfoListener(new MediaPlayer.OnInfoListener() {
            public boolean onInfo(MediaPlayer mp, int what, int extra) {
                if (what == MediaPlayer.MEDIA_INFO_BUFFERING_START) pLabel(pTitle + "  •  carregando...", false);
                else if (what == MediaPlayer.MEDIA_INFO_BUFFERING_END || what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) pLabel(pTitle, true);
                return false;
            }
        });
        v.setOnErrorListener(new MediaPlayer.OnErrorListener() {
            public boolean onError(MediaPlayer mp, int what, int extra) {
                pSend("{\"event\":\"error\",\"what\":" + what + ",\"extra\":" + extra + "}", true);
                // nunca tocou e já falhou 2x: esse formato o Android não abre — devolve pro app tentar do jeito dele
                if (!pEverPlayed && pRetries >= 1) { closePlayer("failed"); return true; }
                retry("erro " + what + "/" + extra);
                return true;
            }
        });
        v.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
            public void onCompletion(MediaPlayer mp) { retry("o stream terminou"); } // ao vivo não "termina": reconecta
        });
        d.setOnKeyListener(new DialogInterface.OnKeyListener() {
            public boolean onKey(DialogInterface di, int keyCode, KeyEvent ev) {
                if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
                    if (ev.getAction() == KeyEvent.ACTION_UP) closePlayer("closed");
                    return true;
                }
                if ((keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) && ev.getAction() == KeyEvent.ACTION_UP) {
                    pLabel(pTitle, true); // mostra o nome do canal
                    return true;
                }
                return false;
            }
        });
        d.setOnCancelListener(new DialogInterface.OnCancelListener() {
            public void onCancel(DialogInterface di) { closePlayer("closed"); }
        });
        d.show();
        try {
            Window w = d.getWindow();
            if (w != null) {
                w.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
                w.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            }
        } catch (Throwable ignore) {}
        v.setVideoURI(Uri.parse(url));
        v.start();
        // vigia: vídeo parado ~15s (sem erro) = reconecta
        pWatch = new Runnable() {
            public void run() {
                if (pView == null) return;
                try {
                    int pos = pView.getCurrentPosition();
                    if (pos != pLastPos) { pLastPos = pos; pLastMove = System.currentTimeMillis(); }
                    else if (System.currentTimeMillis() - pLastMove > 15000) { pLastMove = System.currentTimeMillis(); retry("vídeo parado"); }
                } catch (Throwable ignore) {}
                pH.postDelayed(this, 3000);
            }
        };
        pH.postDelayed(pWatch, 3000);
    }

    private void retry(String why) {
        if (pView == null) return;
        pRetries++;
        long wait = Math.min(10000, 1500L * pRetries);
        pLabel(pTitle + "  •  reconectando (tentativa " + pRetries + ")...", false);
        pSend("{\"event\":\"retry\",\"n\":" + pRetries + ",\"why\":" + q(why) + "}", true);
        pH.postDelayed(new Runnable() {
            public void run() {
                if (pView == null) return;
                try { pView.stopPlayback(); } catch (Throwable ignore) {}
                pLastMove = System.currentTimeMillis();
                pView.setVideoURI(Uri.parse(pUrl));
                pView.start();
            }
        }, wait);
    }

    private void closePlayer(String reason) {
        if (pWatch != null) { pH.removeCallbacks(pWatch); pWatch = null; }
        if (pHideLabel != null) { pH.removeCallbacks(pHideLabel); pHideLabel = null; }
        pH.removeCallbacksAndMessages(null);
        if (pView != null) { try { pView.stopPlayback(); } catch (Throwable ignore) {} pView = null; }
        if (pDialog != null) { try { pDialog.setOnCancelListener(null); pDialog.dismiss(); } catch (Throwable ignore) {} pDialog = null; }
        pLabel = null;
        if (pCb != null) pSend("{\"event\":" + q(reason) + ",\"played\":" + pEverPlayed + "}", false);
    }

    // ================== MINI PLAYER NATIVO ==================
    private FrameLayout mBox;
    private VideoView mView;
    private CallbackContext mCb;
    private String mUrl;
    private int mRetries = 0, mLastPos = -1;
    private boolean mPlayed = false;
    private long mLastMove = 0;
    private Runnable mWatch;
    private final Handler mH = new Handler(Looper.getMainLooper());

    private void mSend(String json, boolean keep) {
        if (mCb == null) return;
        PluginResult r = new PluginResult(PluginResult.Status.OK, json);
        r.setKeepCallback(keep);
        mCb.sendPluginResult(r);
        if (!keep) mCb = null;
    }

    /** O vídeo fica ATRÁS do WebView (que fica transparente só onde a página
     *  deixa um "buraco" no quadro). Assim tudo da página — painel de
     *  diagnóstico, popups, avisos — aparece POR CIMA do vídeo. O fundo da
     *  tela nativa ganha a cor de fundo do app, então o resto fica igual. */
    private void miniOpen(String url, String bg) {
        Activity act = cordova.getActivity();
        ViewGroup content = (ViewGroup) act.findViewById(android.R.id.content);
        if (mBox == null) {
            mBox = new FrameLayout(act);
            mBox.setBackgroundColor(Color.BLACK);
            mBox.setFocusable(false);
            content.addView(mBox, 0, new FrameLayout.LayoutParams(1, 1, Gravity.TOP | Gravity.LEFT));
            try { content.setBackgroundColor(Color.parseColor(bg == null ? "#0B0D16" : bg)); } catch (Throwable t) { content.setBackgroundColor(0xFF0B0D16); }
            try { webView.getView().setBackgroundColor(Color.TRANSPARENT); } catch (Throwable ignore) {}
        }
        if (url.equals(mUrl) && mView != null) return; // já tocando esse canal
        if (mView != null) { try { mView.stopPlayback(); } catch (Throwable ignore) {} mBox.removeView(mView); mView = null; }
        mUrl = url; mRetries = 0; mPlayed = false; mLastPos = -1; mLastMove = System.currentTimeMillis();
        final VideoView v = new VideoView(act);
        v.setFocusable(false);
        mBox.addView(v, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        mView = v;
        v.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
            public void onPrepared(MediaPlayer mp) { mPlayed = true; mRetries = 0; mLastMove = System.currentTimeMillis(); mp.start(); mSend("{\"event\":\"playing\"}", true); }
        });
        v.setOnErrorListener(new MediaPlayer.OnErrorListener() {
            public boolean onError(MediaPlayer mp, int what, int extra) {
                mSend("{\"event\":\"error\",\"what\":" + what + ",\"extra\":" + extra + "}", true);
                if (!mPlayed && mRetries >= 1) { miniClose("failed"); return true; }
                miniRetry("erro " + what + "/" + extra);
                return true;
            }
        });
        v.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
            public void onCompletion(MediaPlayer mp) { miniRetry("o stream terminou"); }
        });
        v.setVideoURI(Uri.parse(url));
        v.start();
        if (mWatch == null) {
            mWatch = new Runnable() {
                public void run() {
                    if (mView == null) { mWatch = null; return; }
                    try {
                        int pos = mView.getCurrentPosition();
                        if (pos != mLastPos) { mLastPos = pos; mLastMove = System.currentTimeMillis(); }
                        else if (System.currentTimeMillis() - mLastMove > 15000) { mLastMove = System.currentTimeMillis(); miniRetry("vídeo parado"); }
                    } catch (Throwable ignore) {}
                    mH.postDelayed(this, 3000);
                }
            };
            mH.postDelayed(mWatch, 3000);
        }
    }

    /** x/y/w/h em pixels CSS * densidade, relativos ao WebView */
    private void miniPlace(int x, int y, int w, int h, boolean visible) {
        if (mBox == null) return;
        int ox = 0, oy = 0;
        try {
            int[] wl = new int[2], cl = new int[2];
            webView.getView().getLocationInWindow(wl);
            ((View) mBox.getParent()).getLocationInWindow(cl);
            ox = wl[0] - cl[0]; oy = wl[1] - cl[1];
        } catch (Throwable ignore) {}
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.max(1, w), Math.max(1, h), Gravity.TOP | Gravity.LEFT);
        lp.setMargins(ox + x, oy + y, 0, 0);
        mBox.setLayoutParams(lp);
        mBox.setVisibility(visible && w > 2 && h > 2 ? View.VISIBLE : View.INVISIBLE);
    }

    private void miniRetry(String why) {
        if (mView == null) return;
        mRetries++;
        long wait = Math.min(10000, 1500L * mRetries);
        mSend("{\"event\":\"retry\",\"n\":" + mRetries + ",\"why\":" + q(why) + "}", true);
        mH.postDelayed(new Runnable() {
            public void run() {
                if (mView == null) return;
                try { mView.stopPlayback(); } catch (Throwable ignore) {}
                mLastMove = System.currentTimeMillis();
                mView.setVideoURI(Uri.parse(mUrl));
                mView.start();
            }
        }, wait);
    }

    private void miniClose(String reason) {
        mH.removeCallbacksAndMessages(null);
        mWatch = null;
        if (mView != null) { try { mView.stopPlayback(); } catch (Throwable ignore) {} mView = null; }
        if (mBox != null) { try { ((ViewGroup) mBox.getParent()).removeView(mBox); } catch (Throwable ignore) {} mBox = null; }
        try { webView.getView().setBackgroundColor(Color.BLACK); } catch (Throwable ignore) {}
        mUrl = null;
        if (mCb != null) mSend("{\"event\":" + q(reason) + ",\"played\":" + mPlayed + "}", false);
    }
}
PIPEOF
echo "🖼️ Plugin de PiP preparado."

PROJECT_NAME="Manager"
APP_ID="com.Manager.Manager"
WORKDIR="$(pwd)/app"
APK_FILE_NAME="Manager.apk"

echo "📦 Iniciando build APK com Cordova + Docker..."

docker run --network host --rm -it \
  -v "$WORKDIR":/workspace \
  beevelop/cordova \
  bash -c "
    set -e

    rm -rf /tmp/app
    echo '🚧 Criando projeto Cordova...'
    npm config set strict-ssl false &&
    export NODE_TLS_REJECT_UNAUTHORIZED=0

    echo '🔨 Forçando uso de Gradle cache...'

    cordova create app $APP_ID $PROJECT_NAME

    cd app

    # cordova-plugin-whitelist NÃO é mais adicionado: desde o cordova-android
    # 10 ele já vem embutido, e o plugin antigo quebra a compilação nas
    # versões novas (o Docker agora usa cordova-android 15).

    echo '🖼️ Adicionando PiP nativo...'
    cordova plugin add /workspace/cordova-plugin-manager-pip

    # girar a tela pra horizontal ao entrar em tela cheia (screen.orientation.lock)
    echo '🔄 Adicionando rotação de tela...'
    cordova plugin add cordova-plugin-screen-orientation

    cp -rf /workspace/config.xml ./
    # o config.xml aponta pra esse arquivo (resource-file) — ele precisa
    # estar na raiz do projeto Cordova, senão: 'Source path does not exist'
    cp -rf /workspace/network_security_config.xml ./

    sed -i 's|<name>.*</name>|<name>$PROJECT_NAME</name>|g' config.xml


    echo ok
    cat config.xml
    echo ok

    echo '🧹 Limpando www...'
    rm -rf www/*

    echo '📄 Copiando arquivos...'
    cp /workspace/index.html www/
    cp /workspace/script.sh www/ 2>/dev/null || true

    echo '📱 Adicionando Android...'
    cordova platform add android

    # sleep 900
    echo '🔨 Gerando APK...'
    cordova build android

    echo '📦 Copiando APK para workspace...'
    cp -rf platforms/android/app/build/outputs/apk/debug/app-debug.apk /workspace/$APK_FILE_NAME 2>/dev/null || \
    cp -rf platforms/android/build/outputs/apk/debug/app-debug.apk /workspace/$APK_FILE_NAME

    echo '✅ Build finalizado!'
  "

ls
cp -rf app/*.apk ./
rm -rf app

echo "🎉 APK gerado na pasta atual: $APK_FILE_NAME"