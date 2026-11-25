package dev.si.dcimgrid;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.ContentProviderOperation;
import android.content.ContentUris;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.text.method.ScrollingMovementMethod;
import android.util.LruCache;
import android.util.Size;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {
    static final String TAG = "DCIMGrid";
    final Uri filesUri = MediaStore.Files.getContentUri("external_primary");
    final ExecutorService pool = Executors.newFixedThreadPool(4);
    final LruCache<Long, Bitmap> cache = new LruCache<>(300);
    final Handler ui = new Handler(Looper.getMainLooper());
    List<Item> items = new ArrayList<>();

    static class Item {
        long id;
        String name;
        String path;
        long size;
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFFF7F7F7);
        LinearLayout center = new LinearLayout(this);
        center.setOrientation(LinearLayout.VERTICAL);
        center.setGravity(Gravity.CENTER);
        int gap = (int)(12 * getResources().getDisplayMetrics().density);
        center.setPadding(gap, gap, gap, gap);

        Button read = new Button(this);
        read.setText("读取 DCIM");
        read.setTextSize(20);
        read.setAllCaps(false);
        center.addView(read, new LinearLayout.LayoutParams(
                (int)(240 * getResources().getDisplayMetrics().density),
                (int)(64 * getResources().getDisplayMetrics().density)));

        Button write = new Button(this);
        write.setText("写入 Hello World");
        write.setTextSize(18);
        write.setAllCaps(false);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                (int)(240 * getResources().getDisplayMetrics().density),
                (int)(56 * getResources().getDisplayMetrics().density));
        wlp.topMargin = gap;
        center.addView(write, wlp);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.CENTER;
        root.addView(center, lp);
        setContentView(root);

        if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.READ_MEDIA_IMAGES}, 1001);
        }

        read.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { showGrid(); }
        });
        write.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { confirmWrite(); }
        });
    }

    void showGrid() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(8 * getResources().getDisplayMetrics().density);
        ll.setPadding(pad, pad, pad, pad);

        TextView header = new TextView(this);
        header.setTextSize(12);
        header.setText("正在读取 DCIM…");
        ll.addView(header);

        GridView grid = new GridView(this);
        grid.setNumColumns(3);
        grid.setHorizontalSpacing(pad);
        grid.setVerticalSpacing(pad);
        grid.setPadding(pad, pad, pad, pad);
        grid.setBackgroundColor(0xFFFFFFFF);
        ll.addView(grid, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(ll);

        new Thread(new Runnable() {
            @Override public void run() {
                final List<Item> list = loadItems();
                ui.post(new Runnable() {
                    @Override public void run() {
                        items = list;
                        header.setText("DCIM " + list.size() + " 张 · 无授权目录\n" + mountRoot());
                        grid.setAdapter(new Adapter(list));
                    }
                });
            }
        }).start();

        grid.setOnItemClickListener(new android.widget.AdapterView.OnItemClickListener() {
            @Override public void onItemClick(android.widget.AdapterView<?> p, View v, int pos, long id) {
                if (pos >= 0 && pos < items.size()) showFull(items.get(pos));
            }
        });
    }


    List<Item> loadItems() {
        List<Item> out = new ArrayList<>();
        ContentResolver cr = getContentResolver();
        String[] proj = {"_id", "_data", "_display_name", "_size", "media_type"};
        try (Cursor c = cr.query(filesUri, proj, null, null, "_id DESC")) {
            if (c == null) return out;
            while (c.moveToNext()) {
                String path = c.getString(1);
                String name = c.getString(2);
                long size = c.getLong(3);
                int type = c.getInt(4);
                if (path != null && path.startsWith("/storage/emulated/0/DCIM/") &&
                        (type == 1 || isImage(path))) {
                    Item it = new Item();
                    it.id = c.getLong(0);
                    it.path = path;
                    it.name = name == null ? path.substring(path.lastIndexOf('/') + 1) : name;
                    it.size = size;
                    out.add(it);
                }
            }
        } catch (Throwable ignored) { }
        return out;
    }

    static boolean isImage(String p) {
        String s = p.toLowerCase();
        return s.endsWith(".jpg") || s.endsWith(".jpeg") || s.endsWith(".png") ||
                s.endsWith(".webp") || s.endsWith(".heic") || s.endsWith(".heif") ||
                s.endsWith(".gif") || s.endsWith(".bmp");
    }

    String mountRoot() {
        try (BufferedReader br = new BufferedReader(new FileReader("/proc/self/mountinfo"))) {
            String line;
            while ((line = br.readLine()) != null) {
                if (line.contains(" /storage/emulated/0 ")) return line;
            }
        } catch (Throwable ignored) { }
        return "mountinfo: /storage/emulated/0 not found";
    }

    Bitmap thumb(long id) {
        Bitmap b = cache.get(id);
        if (b != null) return b;
        try {
            b = getContentResolver().loadThumbnail(
                    ContentUris.withAppendedId(filesUri, id), new Size(360, 360), null);
        } catch (Throwable t) {
            try (InputStream is = getContentResolver().openInputStream(
                    ContentUris.withAppendedId(filesUri, id))) {
                BitmapFactory.Options o = new BitmapFactory.Options();
                o.inSampleSize = 4;
                b = BitmapFactory.decodeStream(is, null, o);
            } catch (Throwable ignored) { }
        }
        if (b != null) cache.put(id, b);
        return b;
    }

    void loadInto(ImageView iv, long id) {
        iv.setTag(id);
        Bitmap b = cache.get(id);
        if (b != null) { iv.setImageBitmap(b); return; }
        iv.setImageResource(android.R.drawable.ic_menu_gallery);
        pool.execute(new Runnable() {
            @Override public void run() {
                final Bitmap bmp = thumb(id);
                if (bmp == null) return;
                ui.post(new Runnable() {
                    @Override public void run() {
                        if (iv.getTag() != null && iv.getTag().equals(id)) iv.setImageBitmap(bmp);
                    }
                });
            }
        });
    }

    class Adapter extends BaseAdapter {
        final List<Item> data;
        Adapter(List<Item> d) { data = d; }
        @Override public int getCount() { return data.size(); }
        @Override public Object getItem(int i) { return data.get(i); }
        @Override public long getItemId(int i) { return data.get(i).id; }
        @Override public View getView(int pos, View cv, ViewGroup parent) {
            LinearLayout cell;
            if (cv instanceof LinearLayout) cell = (LinearLayout) cv;
            else {
                cell = new LinearLayout(MainActivity.this);
                cell.setOrientation(LinearLayout.VERTICAL);
                cell.setBackgroundColor(0xFFFFFFFF);
                ImageView iv = new ImageView(MainActivity.this);
                iv.setLayoutParams(new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        (int)(120 * getResources().getDisplayMetrics().density)));
                iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
                iv.setId(1);
                cell.addView(iv);
                TextView tv = new TextView(MainActivity.this);
                tv.setTextSize(10);
                tv.setMaxLines(1);
                tv.setEllipsize(android.text.TextUtils.TruncateAt.END);
                tv.setPadding(4, 4, 4, 4);
                tv.setId(2);
                cell.addView(tv);
            }
            Item it = data.get(pos);
            ImageView iv = cell.findViewById(1);
            TextView tv = cell.findViewById(2);
            tv.setText(it.name);
            loadInto(iv, it.id);
            return cell;
        }
    }

    void showFull(Item it) {
        ImageView iv = new ImageView(this);
        iv.setAdjustViewBounds(true);
        iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
        iv.setBackgroundColor(0xFF000000);
        iv.setImageResource(android.R.drawable.ic_menu_gallery);
        AlertDialog.Builder b = new AlertDialog.Builder(this);
        b.setTitle(it.name + "  " + it.size + "B");
        b.setView(iv);
        b.setPositiveButton("关闭", null);
        AlertDialog d = b.create();
        d.show();
        pool.execute(new Runnable() {
            @Override public void run() {
                Bitmap bmp = null;
                try {
                    bmp = getContentResolver().loadThumbnail(
                            ContentUris.withAppendedId(filesUri, it.id), new Size(1440, 1440), null);
                } catch (Throwable t) {
                    try (InputStream is = getContentResolver().openInputStream(
                            ContentUris.withAppendedId(filesUri, it.id))) {
                        bmp = BitmapFactory.decodeStream(is);
                    } catch (Throwable ignored) { }
                }
                final Bitmap fb = bmp;
                if (fb != null) ui.post(new Runnable() {
                    @Override public void run() { iv.setImageBitmap(fb); }
                });
            }
        });
    }

    void confirmWrite() {
        new android.app.AlertDialog.Builder(this)
                .setTitle("写入 Hello World")
                .setMessage("将往 Download 写入一个 Hello World（11B），用于验证 SI 写拦截。\n\n补丁生效时应被拦截；未生效时会出现在 Download。")
                .setPositiveButton("写入", new android.content.DialogInterface.OnClickListener() {
                    @Override public void onClick(android.content.DialogInterface d, int w) { writeHelloWorld(); }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    void writeHelloWorld() {
        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    ContentValues v = new ContentValues();
                    v.put(MediaStore.Downloads.DISPLAY_NAME, "Hello World");
                    v.put(MediaStore.Downloads.MIME_TYPE, "text/plain");
                    v.put(MediaStore.Downloads.RELATIVE_PATH, "Download/");
                    v.put(MediaStore.Downloads.IS_PENDING, 1);
                    Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                    if (u == null) {
                        showWriteResult("BLOCKED\n\nMediaStore insert 返回 null。\n预期：补丁生效。");
                        return;
                    }
                    try (java.io.OutputStream os = getContentResolver().openOutputStream(u)) {
                        os.write("Hello World".getBytes());
                    }
                    ContentValues done = new ContentValues();
                    done.put(MediaStore.Downloads.IS_PENDING, 0);
                    getContentResolver().update(u, done, null, null);
                    String extra = "";
                    try (Cursor c = getContentResolver().query(u,
                            new String[]{"_data", "relative_path", "_display_name"}, null, null, null)) {
                        if (c != null && c.moveToFirst()) {
                            extra = "\n_data=" + c.getString(0)
                                    + "\nrel=" + c.getString(1)
                                    + "\nname=" + c.getString(2);
                        }
                    } catch (Throwable ignored) { }
                    showWriteResult("WROTE\n\nURI=" + u + extra + "\n\n请到 Download 查看 Hello World。");
                } catch (Throwable t) {
                    showWriteResult("BLOCKED\n\n" + t.getClass().getSimpleName() + ": " + t.getMessage()
                            + "\n\n预期：补丁生效。");
                }
            }
        }).start();
    }

    void showWriteResult(final String msg) {
        android.util.Log.i(TAG, "WRITE " + msg.replace("\n", " | "));
        ui.post(new Runnable() {
            @Override public void run() {
                new android.app.AlertDialog.Builder(MainActivity.this)
                        .setTitle("写测试结果")
                        .setMessage(msg)
                        .setPositiveButton("关闭", null)
                        .show();
            }
        });
    }
}
