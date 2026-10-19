package inventree.inventree_app;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import java.io.File;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.Set;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

/** Validates an update against the installed app before sharing it with Android. */
final class AppUpdateInstaller {
    static void register(Activity activity, BinaryMessenger messenger) {
        new MethodChannel(messenger, "omni_gears/app_updates")
                .setMethodCallHandler((call, result) -> {
                    try {
                        switch (call.method) {
                            case "canInstallPackages":
                                result.success(canInstall(activity));
                                break;
                            case "openInstallSettings":
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    activity.startActivity(new Intent(
                                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                            Uri.parse("package:" + activity.getPackageName())));
                                }
                                result.success(null);
                                break;
                            case "installApk":
                                if (!canInstall(activity)) {
                                    result.error("INSTALL_PERMISSION", "Allow Omni Gears to install app updates in Android settings.", null);
                                    return;
                                }
                                String path = call.argument("path");
                                Number expectedBuild = call.argument("buildNumber");
                                File apk = validate(activity, path, expectedBuild);
                                Uri uri = FileProvider.getUriForFile(activity,
                                        activity.getPackageName() + ".appupdates.provider", apk);
                                Intent intent = new Intent(Intent.ACTION_VIEW)
                                        .setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                                activity.startActivity(intent);
                                result.success(null);
                                break;
                            default:
                                result.notImplemented();
                        }
                    } catch (Exception error) {
                        result.error("UPDATE_INSTALL_FAILED", error.getMessage(), null);
                    }
                });
    }

    private static boolean canInstall(Activity activity) {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O
                || activity.getPackageManager().canRequestPackageInstalls();
    }

    @SuppressWarnings("deprecation")
    private static File validate(Activity activity, String path, Number expectedBuild) throws Exception {
        if (path == null || expectedBuild == null) {
            throw new SecurityException("The update installer is missing information.");
        }
        File apk = new File(path).getCanonicalFile();
        File directory = new File(activity.getCacheDir(), "omni-updates").getCanonicalFile();
        if (!apk.getPath().startsWith(directory.getPath() + File.separator)
                || !apk.isFile() || apk.length() == 0 || apk.length() > 512L * 1024 * 1024) {
            throw new SecurityException("The downloaded update file is not valid.");
        }
        PackageManager pm = activity.getPackageManager();
        int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
        PackageInfo installed = pm.getPackageInfo(activity.getPackageName(), flags);
        PackageInfo candidate = pm.getPackageArchiveInfo(apk.getPath(), flags);
        if (candidate == null || !activity.getPackageName().equals(candidate.packageName)) {
            throw new SecurityException("This installer is for a different app.");
        }
        long installedBuild = versionCode(installed);
        long candidateBuild = versionCode(candidate);
        if (candidateBuild <= installedBuild || candidateBuild != expectedBuild.longValue()) {
            throw new SecurityException("The installer is not the expected newer version.");
        }
        if (candidate.applicationInfo == null
                || candidate.applicationInfo.minSdkVersion > Build.VERSION.SDK_INT) {
            throw new SecurityException("This update requires a newer Android version.");
        }
        Set<String> installedSigners = signers(installed);
        if (installedSigners.isEmpty() || !installedSigners.equals(signers(candidate))) {
            throw new SecurityException("This update was not signed by your app's publisher.");
        }
        return apk;
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo info) {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? info.getLongVersionCode() : info.versionCode;
    }

    @SuppressWarnings("deprecation")
    private static Set<String> signers(PackageInfo info) throws Exception {
        Signature[] signatures = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? (info.signingInfo == null ? null : info.signingInfo.getApkContentsSigners())
                : info.signatures;
        Set<String> result = new HashSet<>();
        if (signatures != null) {
            for (Signature signature : signatures) {
                byte[] digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray());
                StringBuilder hex = new StringBuilder();
                for (byte value : digest) hex.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
                result.add(hex.toString());
            }
        }
        return result;
    }
}
