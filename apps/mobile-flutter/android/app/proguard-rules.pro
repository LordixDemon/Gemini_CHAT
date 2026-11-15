# Fix mobile_scanner-6.0.11 consumer rule (`-keep class com.google.mlkit.*` missed subpackages under R8)
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.photos.** { *; }

# Keep Firebase ComponentDiscovery / ComponentRegistrar instantiated via reflection in MlKitInitProvider
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.firebase.components.** { *; }

# Keep Google Play Services / Dynamite / ML Kit internal barcode classes
-keep class com.google.android.gms.common.** { *; }
-keep class com.google.android.gms.dynamite.** { *; }
-keep class com.google.android.gms.tasks.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode_bundled.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }

# Keep CameraX & mobile_scanner plugin classes
-keep class androidx.camera.** { *; }
-keep class dev.steenbakker.mobile_scanner.** { *; }

-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
