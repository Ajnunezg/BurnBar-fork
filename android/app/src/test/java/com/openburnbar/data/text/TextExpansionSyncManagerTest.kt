package com.openburnbar.data.text

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.openburnbar.data.db.TextExpansionDao
import com.openburnbar.data.db.TextExpansionSnippetEntity
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Snippet sync consent (mirrors the Mac's AccountManagerCloudSyncConsentTests): snippets
 * stay on the device until the user opts in, an upgrade that was already syncing keeps
 * syncing, and a stored choice always wins.
 */
class TextExpansionSyncManagerTest {
    private val context = mockk<Context>(relaxed = true)
    private val dao = mockk<TextExpansionDao>(relaxed = true)
    private val prefs = mockk<SharedPreferences>(relaxed = true)
    private val editor = mockk<SharedPreferences.Editor>(relaxed = true)

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { context.getSharedPreferences(TextExpansionCloudSyncPreference.PREFS_NAME, Context.MODE_PRIVATE) } returns prefs
        every { prefs.edit() } returns editor
        every { editor.putBoolean(any(), any()) } returns editor
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    @Test
    fun syncSkipsIfDisabledInSettings() = runBlocking {
        storedChoice(false)

        val result = TextExpansionSyncManager(context, dao, mockk(relaxed = true)).sync()

        assertTrue(result.isSuccess)
        verify(exactly = 0) { dao.getUnsynced(any()) }
    }

    @Test
    fun freshInstallUploadsNothingAndStoresSyncOff() = runBlocking {
        undecided(localRows = listOf(snippet()))

        val result = TextExpansionSyncManager(context, dao, mockk(relaxed = true)).sync()

        assertTrue(result.isSuccess)
        verify(exactly = 0) { dao.getUnsynced(any()) }
        verify { editor.putBoolean(TextExpansionCloudSyncPreference.KEY, false) }
    }

    @Test
    fun upgradeThatAlreadyUploadedKeepsSyncOn() {
        undecided(localRows = listOf(snippet(), snippet(syncedAtMillis = 1L)))

        assertTrue(TextExpansionCloudSyncPreference.resolve(prefs, dao))
        verify { editor.putBoolean(TextExpansionCloudSyncPreference.KEY, true) }
    }

    @Test
    fun upgradeThatAlreadyDownloadedKeepsSyncOn() = runBlocking {
        undecided(localRows = listOf(snippet(sourceDeviceID = "mac-device-1")))

        assertTrue(TextExpansionCloudSyncPreference.resolveInBackground(prefs) { dao })
        verify { editor.putBoolean(TextExpansionCloudSyncPreference.KEY, true) }
    }

    @Test
    fun storedChoiceWinsWithoutConsultingTheDatabase() {
        storedChoice(false)
        every { dao.getAllIncludingDeleted() } returns listOf(snippet(syncedAtMillis = 1L))
        assertFalse(TextExpansionCloudSyncPreference.resolve(prefs, dao))

        storedChoice(true)
        assertTrue(TextExpansionCloudSyncPreference.resolve(prefs, dao))

        verify(exactly = 0) { dao.getAllIncludingDeleted() }
        verify(exactly = 0) { editor.putBoolean(any(), any()) }
    }

    @Test
    fun undecidedChoiceReadsAsOffBeforeResolution() {
        // Nothing stored: SharedPreferences hands back the caller's default.
        every { prefs.getBoolean(TextExpansionCloudSyncPreference.KEY, any()) } answers { secondArg() }

        assertFalse(TextExpansionCloudSyncPreference.storedOrOff(prefs))
    }

    private fun storedChoice(enabled: Boolean) {
        every { prefs.contains(TextExpansionCloudSyncPreference.KEY) } returns true
        every { prefs.getBoolean(TextExpansionCloudSyncPreference.KEY, any()) } returns enabled
    }

    private fun undecided(localRows: List<TextExpansionSnippetEntity>) {
        every { prefs.contains(TextExpansionCloudSyncPreference.KEY) } returns false
        every { dao.getAllIncludingDeleted() } returns localRows
    }

    private fun snippet(syncedAtMillis: Long? = null, sourceDeviceID: String? = null) = TextExpansionSnippetEntity(
        id = "snippet-${syncedAtMillis ?: 0}-${sourceDeviceID.orEmpty()}",
        title = "Greeting",
        trigger = "hello",
        body = "Hi there",
        mode = "static",
        createdAtMillis = 0L,
        updatedAtMillis = 0L,
        syncedAtMillis = syncedAtMillis,
        sourceDeviceID = sourceDeviceID,
    )
}
