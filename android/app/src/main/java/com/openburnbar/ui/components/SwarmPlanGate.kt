package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.ui.theme.LocalSwarmAgentsTabSurface

/**
 * The shared Where/When gate for every swarm-family backdrop renderer.
 * [rememberSwarmRenderPlan] is the single plan-resolution point — platform
 * sensors, Reduce Motion, and the agents-tab surface signal feed
 * [SwarmBackgroundPowerPolicy.resolve] — and [SwarmPlanGate] is the dispatch
 * seam: kernel, constellation, and classic-swarm renderers all check out of
 * the same plan, matching the iOS WebsiteBackgroundView.swarmBody block where
 * the whole live backdrop is plan-gated. The engine side stays in
 * SwarmBackground.kt; this file owns the resolve + gate helpers.
 */

// Frame-loop floor: the swarm physics were tuned at 60Hz, so the plan's
// frame-rate cap sets the loop floor — 60Hz is only the fallback when a plan
// carries no cap.
private const val MIN_STEP_INTERVAL_NANOS = 16_000_000L

/**
 * Applies the resolved plan's particle scale to the base count (iOS:
 * `resolvedParticleCount(scale:)`). Internal for JVM tests; the swarm
 * composable is the only production caller.
 */
internal fun scaledSwarmParticleCount(baseCount: Int, plan: SwarmBackgroundRenderPlan): Int = (baseCount * plan.particleScale).toInt().coerceAtLeast(1)

/**
 * Frame-loop floor for the resolved plan: the plan's fps cap, or the legacy
 * 60Hz floor when the plan carries no cap. Internal for JVM tests.
 */
internal fun swarmFrameIntervalNanos(plan: SwarmBackgroundRenderPlan): Long = plan.maxFrameRate
    ?.takeIf { it > 0.0 }
    ?.let { (1_000_000_000.0 / it).toLong() }
    ?: MIN_STEP_INTERVAL_NANOS

/** Live platform sensor readings for the swarm power policy. */
internal data class SwarmEnvironmentSnapshot(
    val isPowerConnected: Boolean,
    val isWifiConnected: Boolean,
    val isPowerSaveMode: Boolean,
    val sceneActive: Boolean,
)

/**
 * Collects the platform sensors the power policy needs. Battery, network,
 * and power-save come from the process-wide [SwarmEnvironmentMonitor] hot
 * flows (seeded with a synchronous snapshot, then live); scene activity
 * comes from the composition's lifecycle owner. Every transition recomposes
 * the gate — sensors feed [SwarmBackgroundPowerPolicy.resolve], nothing
 * bypasses it.
 */
@Composable
internal fun swarmEnvironmentSnapshot(): SwarmEnvironmentSnapshot {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val appContext = context.applicationContext
    val monitor = remember(appContext) { SwarmEnvironmentMonitor.get(appContext) }
    val isPowerConnected by monitor.isPowerConnected.collectAsState()
    val isWifiConnected by monitor.isWifiConnected.collectAsState()
    val isPowerSaveMode by monitor.isPowerSaveMode.collectAsState()
    var lifecycleState by remember(lifecycleOwner) { mutableStateOf(lifecycleOwner.lifecycle.currentState) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, _ -> lifecycleState = lifecycleOwner.lifecycle.currentState }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    return SwarmEnvironmentSnapshot(
        isPowerConnected = isPowerConnected,
        isWifiConnected = isWifiConnected,
        isPowerSaveMode = isPowerSaveMode,
        sceneActive = isSwarmSceneActive(lifecycleState),
    )
}

/**
 * Current value of the persisted Where/When pickers, for the
 * [SwarmBackground] default prefs (composable-call default, like
 * [adaptiveParticleCount]).
 */
@Composable
internal fun persistedSwarmBackgroundPreferences(): SwarmBackgroundPreferences {
    val preferences by rememberSwarmBackgroundPreferences()
    return preferences
}

/**
 * The single plan-resolution point every swarm-family renderer shares.
 * [SwarmBackground] uses it to gate its own simulation; [WebsiteBackground]
 * uses it to gate the kernel and constellation renderers so the Where/When
 * pickers apply to whichever swarm renderer is actually on screen. Reads the
 * platform sensors, Reduce Motion, and the agents-tab surface signal
 * ([LocalSwarmAgentsTabSurface]); callers supply the visibility they render
 * under. Internal so sibling backdrop composables share it.
 */
@Composable
internal fun rememberSwarmRenderPlan(
    visibility: MobileBackgroundVisibility,
    preferences: SwarmBackgroundPreferences = persistedSwarmBackgroundPreferences(),
): SwarmBackgroundRenderPlan {
    val reduceMotion = LocalAuroraReduceMotion.current
    val surfaceEligible = LocalSwarmAgentsTabSurface.current
    val environment = swarmEnvironmentSnapshot()
    val conditionMet =
        SwarmEnvironmentConditionEvaluator.meetsCondition(
            condition = preferences.condition,
            isPowerConnected = environment.isPowerConnected,
            isWifiConnected = environment.isWifiConnected,
        )
    return SwarmBackgroundPowerPolicy.resolve(
        location = preferences.location,
        conditionMet = conditionMet,
        requestedVisibility = visibility,
        scenePhaseActive = environment.sceneActive,
        isLowPowerModeEnabled = environment.isPowerSaveMode,
        reduceMotion = reduceMotion,
        surfaceEligible = surfaceEligible,
    )
}

/**
 * The static backdrop frame: the flat field color with no Canvas and no
 * animation clock, matching the iOS `.staticBackdrop` plan. Shared by every
 * renderer the plan gates.
 */
@Composable
internal fun SwarmStaticBackdrop(modifier: Modifier = Modifier, isDark: Boolean) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(if (isDark) Color(0xFF050508) else Color(0xFFF3EFE7)),
    )
}

/**
 * The shared Where/When gate for a swarm-family renderer: resolves the plan
 * once, then either runs [live] ([SwarmRenderMode.LIVE]) or renders the plan's
 * fallback — the aurora backdrop for [SwarmRenderMode.DISABLED_FALLBACK]
 * (iOS `.disabledFallback → AuroraBackdrop`), the flat field for
 * [SwarmRenderMode.STATIC_BACKDROP]. Every dispatch point that can reach a
 * live particle renderer goes through this so the pickers can never be
 * bypassed by whichever renderer happens to be active.
 */
@Composable
internal fun SwarmPlanGate(
    modifier: Modifier = Modifier,
    visibility: MobileBackgroundVisibility = MobileBackgroundVisibility.PROMINENT,
    isDark: Boolean = isSystemInDarkTheme(),
    preferences: SwarmBackgroundPreferences = persistedSwarmBackgroundPreferences(),
    live: @Composable () -> Unit,
) {
    when (rememberSwarmRenderPlan(visibility = visibility, preferences = preferences).mode) {
        SwarmRenderMode.LIVE -> live()
        SwarmRenderMode.DISABLED_FALLBACK -> AuroraAnimatedBackdrop(
            isDark = isDark,
            density = AuroraDensity.FULL,
            reduceMotion = LocalAuroraReduceMotion.current,
        )
        SwarmRenderMode.STATIC_BACKDROP -> SwarmStaticBackdrop(modifier = modifier, isDark = isDark)
    }
}

/**
 * Power-connected predicate over the `BatteryManager.EXTRA_PLUGGED` extra: 0
 * means on battery, any nonzero plug source (AC/USB/wireless) means
 * connected. Internal for JVM tests; the monitor is the only caller.
 */
internal fun isSwarmPowerConnectedFromPluggedExtra(plugged: Int): Boolean = plugged != 0

/**
 * Wi-Fi predicate over the active network's transports. Counts Wi-Fi or
 * wired Ethernet as connected, matching iOS
 * (`usesInterfaceType(.wifi) || usesInterfaceType(.wiredEthernet)`).
 * Internal for JVM tests; the monitor is the only caller.
 */
internal fun isSwarmWifiConnectedFromTransports(hasWifiTransport: Boolean, hasEthernetTransport: Boolean): Boolean = hasWifiTransport || hasEthernetTransport

/**
 * Scene-active predicate over the composition lifecycle state: only RESUMED
 * counts as active (iOS: `scenePhase == .active`). Internal for JVM tests.
 */
internal fun isSwarmSceneActive(state: Lifecycle.State): Boolean = state.isAtLeast(Lifecycle.State.RESUMED)

@Composable
internal fun adaptiveParticleCount(): Int {
    // Power-save throttling moved into the render plan (SUBTLE_LIVE scales the
    // count); this stays the full device-class base.
    val config = LocalConfiguration.current
    val isTabletish = config.smallestScreenWidthDp >= 600
    return if (isTabletish) 1080 else 520
}
