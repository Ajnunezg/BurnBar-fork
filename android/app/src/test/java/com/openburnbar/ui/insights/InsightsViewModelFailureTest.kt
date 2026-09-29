package com.openburnbar.ui.insights

import android.app.Application
import android.content.SharedPreferences
import com.openburnbar.data.insights.InsightAnalysisAuditEntry
import com.openburnbar.data.insights.InsightAnalysisRequest
import com.openburnbar.data.insights.InsightAnalysisResult
import com.openburnbar.data.insights.InsightEgressTier
import com.openburnbar.data.insights.InsightFilter
import com.openburnbar.data.insights.InsightModelTag
import com.openburnbar.data.insights.services.AndroidHermesInsightAnalysisGateway
import com.openburnbar.data.insights.services.AndroidInsightAnalysisEngine
import com.openburnbar.data.insights.services.AndroidInsightCredentialStore
import com.openburnbar.data.insights.services.AndroidInsightStringStorage
import com.openburnbar.data.insights.services.InMemoryInsightDataSource
import com.openburnbar.data.insights.services.InsightAggregator
import com.openburnbar.data.insights.services.InsightAnalysisModelGateway
import com.openburnbar.data.repos.InsightAnalysisAuditLogRepository
import io.mockk.every
import io.mockk.mockk
import java.net.SocketTimeoutException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Ordinary gateway failures (a timed-out relay, an HTTP 503) must settle into
 * the ViewModel's error state and a terminal audit row. Before, only
 * FirebaseException / BurnBarProSubscriptionRequiredException were caught: any
 * other exception escaped viewModelScope and the audit row stayed STARTED.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class InsightsViewModelFailureTest {
    @get:Rule
    val files = TemporaryFolder()

    private lateinit var application: Application

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val preferences = mockk<SharedPreferences>(relaxed = true)
        every { preferences.getString(any(), any()) } returns null
        every { preferences.getBoolean(any(), any()) } returns false
        application = mockk(relaxed = true)
        every { application.filesDir } returns files.root
        every { application.getSharedPreferences(any(), any()) } returns preferences
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `a relay network timeout settles into the error state and a failed audit row`() {
        val viewModel = viewModelRoutedThrough(Interceptor { throw SocketTimeoutException("hermes relay timed out") })

        viewModel.load()
        awaitSettled(viewModel)

        assertEquals(
            "Insights couldn't reach the analysis service. Check your connection and try again.",
            viewModel.error.value,
        )
        val audit = latestAudit()
        assertEquals(InsightAnalysisAuditEntry.Status.FAILED, audit.status)
        assertEquals("hermes relay timed out", audit.errorDescription)
        assertTrue(audit.completedAt != null)
    }

    @Test
    fun `an HTTP error from the gateway settles into the error state and a failed audit row`() {
        val viewModel =
            viewModelRoutedThrough(
                Interceptor { chain ->
                    Response.Builder()
                        .request(chain.request())
                        .protocol(Protocol.HTTP_1_1)
                        .code(503)
                        .message("Service Unavailable")
                        .body("{}".toResponseBody("application/json".toMediaType()))
                        .build()
                },
            )

        viewModel.refresh()
        awaitSettled(viewModel)

        assertEquals("Hermes Insights returned HTTP 503", viewModel.error.value)
        assertEquals(InsightAnalysisAuditEntry.Status.FAILED, latestAudit().status)
    }

    @Test
    fun `a follow-up whose relay fails falls back to disclosed local rules instead of throwing`() {
        val viewModel = viewModelRoutedThrough(Interceptor { throw SocketTimeoutException("relay down") })

        viewModel.ask("Why did spend spike?")
        awaitSettled(viewModel)

        assertNull(viewModel.error.value)
        val answer = requireNotNull(viewModel.analysis.value?.briefingAnswer)
        assertTrue(answer.isFallback)
        assertEquals("Hermes → Local rules", answer.modelDisplayName)
        assertEquals(InsightAnalysisAuditEntry.Status.SUCCEEDED, latestAudit().status)
    }

    @Test
    fun `a cancelled analysis settles its audit row as cancelled`() = runBlocking {
        val auditLog = InsightAnalysisAuditLogRepository(application)
        val tag =
            InsightModelTag(
                providerKey = "stalled",
                modelID = "stalled-model",
                displayName = "Stalled",
                egressTier = InsightEgressTier.USER_KEY,
            )
        val entered = CompletableDeferred<Unit>()
        val stalled =
            object : InsightAnalysisModelGateway {
                override val providerKey: String = "stalled"
                override val displayName: String = "Stalled"
                override val models: List<InsightModelTag> = listOf(tag)

                override suspend fun analyze(request: InsightAnalysisRequest): InsightAnalysisResult {
                    entered.complete(Unit)
                    awaitCancellation()
                }
            }
        val engine = AndroidInsightAnalysisEngine(auditLog = auditLog, gateways = mapOf("stalled" to stalled))
        val context =
            InsightAggregator.buildContext(
                digest = InMemoryInsightDataSource().buildDigest(InsightFilter()),
                includedDataSources = listOf("firestore_rollups"),
            )

        val run = launch(Dispatchers.Default) {
            engine.analyze(InsightAnalysisRequest(prompt = "Brief", context = context, selectedModel = tag))
        }
        entered.await()
        run.cancelAndJoin()

        assertEquals(InsightAnalysisAuditEntry.Status.CANCELLED, auditLog.readAll().last().status)
    }

    private fun viewModelRoutedThrough(interceptor: Interceptor): InsightsViewModel {
        val hermes =
            AndroidHermesInsightAnalysisGateway(
                baseURLProvider = { "https://hermes.invalid" },
                client = OkHttpClient.Builder().addInterceptor(interceptor).build(),
            )
        return InsightsViewModel(
            application,
            InMemoryInsightDataSource(),
            hermes,
            AndroidInsightCredentialStore(MemoryStorage(), MemoryStorage(), null),
        ).also { it.selectModel(hermes.models.first()) }
    }

    private fun awaitSettled(viewModel: InsightsViewModel) = runBlocking {
        withTimeout(10_000) { viewModel.isLoading.first { !it } }
    }

    private fun latestAudit(): InsightAnalysisAuditEntry = runBlocking {
        InsightAnalysisAuditLogRepository(application).readAll().last()
    }
}

private class MemoryStorage : AndroidInsightStringStorage {
    private val values = linkedMapOf<String, String>()

    override fun getString(key: String): String? = values[key]

    override fun putString(key: String, value: String): Boolean {
        values[key] = value
        return true
    }

    override fun remove(key: String): Boolean = values.remove(key) != null

    override fun keys(): Set<String> = values.keys.toSet()
}
