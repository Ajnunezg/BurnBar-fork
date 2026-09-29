package com.openburnbar.data.text

import android.content.Context
import android.content.SharedPreferences
import com.openburnbar.data.db.TextExpansionDao
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Snippets are where people paste secrets, so syncing them to OpenBurnBar Cloud is
 * opt-in. Android has no master Cloud sync switch (signing in is what connects it),
 * so this preference is the only gate on snippet uploads.
 *
 * A stored choice always wins. The switch used to default ON without being stored,
 * so an install with no stored choice decides once, from evidence: ON only if a local
 * snippet already went through cloud sync (the install was syncing), OFF otherwise,
 * which covers every new install.
 */
object TextExpansionCloudSyncPreference {
    const val PREFS_NAME = "text_expansion_settings"
    const val KEY = "cloud_sync_enabled"

    fun prefs(context: Context): SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** The stored choice for display before [resolve] runs; undecided reads as off. */
    fun storedOrOff(prefs: SharedPreferences): Boolean = prefs.getBoolean(KEY, false)

    /** Resolves the choice, storing it the first time. Queries the database: call it off the main thread. */
    fun resolve(prefs: SharedPreferences, dao: TextExpansionDao): Boolean {
        if (prefs.contains(KEY)) return prefs.getBoolean(KEY, false)
        // Uploads set syncedAtMillis; only a downloaded cloud document stamps sourceDeviceID.
        val alreadySyncing = dao.getAllIncludingDeleted().any { it.syncedAtMillis != null || it.sourceDeviceID != null }
        prefs.edit().putBoolean(KEY, alreadySyncing).apply()
        return alreadySyncing
    }

    /** [resolve] on the IO dispatcher, for UI callers. */
    suspend fun resolveInBackground(prefs: SharedPreferences, dao: () -> TextExpansionDao): Boolean = withContext(Dispatchers.IO) { resolve(prefs, dao()) }
}
