package com.openburnbar.ui.settings

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Wallpaper
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.SwarmBackgroundCondition
import com.openburnbar.ui.components.SwarmBackgroundLocation
import com.openburnbar.ui.components.SwarmBackgroundPreferencesStore
import com.openburnbar.ui.components.swarmConditionSectionVisible
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius

/**
 * Swarm Where/When pickers, the Android port of the iOS
 * `SwarmBackgroundSettingsView` sections. Where always renders; When only
 * renders while the swarm is enabled somewhere ([swarmConditionSectionVisible]).
 * Selections persist via [SwarmBackgroundPreferencesStore] and feed the
 * unchanged power-policy gate.
 */
@Composable
internal fun ThemePrefsSwarmSchedulingSection(
    router: SettingsRouter,
    swarmLocation: SwarmBackgroundLocation,
    swarmCondition: SwarmBackgroundCondition,
    useWebsiteBackground: Boolean,
    haptic: HapticFeedback,
) {
    val context = LocalContext.current
    val swarmPrefsStore = remember(context) { SwarmBackgroundPreferencesStore.get(context) }
    ThemePrefsDivider()
    ThemePrefsSwarmPicker(
        highlighted = router.highlightedAnchor == SettingsAnchor.SWARM_LOCATION,
        icon = Icons.Filled.Wallpaper,
        eyebrow = "Where",
        title = "Show Swarms",
        footer = "Controls where the live background is rendered. 'Everywhere' applies to all tabs and surfaces where it is visually supported.",
        options = SwarmBackgroundLocation.entries.map { it.wireValue },
        selectedIndex = SwarmBackgroundLocation.entries.indexOf(swarmLocation),
        useWebsiteBackground = useWebsiteBackground,
        haptic = haptic,
        onSelect = { swarmPrefsStore.setLocation(SwarmBackgroundLocation.entries[it]) },
    )
    if (swarmConditionSectionVisible(swarmLocation)) {
        ThemePrefsDivider()
        ThemePrefsSwarmPicker(
            highlighted = router.highlightedAnchor == SettingsAnchor.SWARM_CONDITION,
            icon = Icons.Filled.AutoAwesome,
            eyebrow = "When",
            title = "Condition",
            footer = "Live backgrounds use system resources. Restricting them to Wi-Fi or Power Connected saves battery and data.",
            options = SwarmBackgroundCondition.entries.map { it.wireValue },
            selectedIndex = SwarmBackgroundCondition.entries.indexOf(swarmCondition),
            useWebsiteBackground = useWebsiteBackground,
            haptic = haptic,
            onSelect = { swarmPrefsStore.setCondition(SwarmBackgroundCondition.entries[it]) },
        )
    }
}

@Composable
private fun ThemePrefsSwarmPicker(
    highlighted: Boolean,
    icon: ImageVector,
    eyebrow: String,
    title: String,
    footer: String,
    options: List<String>,
    selectedIndex: Int,
    useWebsiteBackground: Boolean,
    haptic: HapticFeedback,
    onSelect: (Int) -> Unit,
) {
    val haloColor by animateColorAsState(
        targetValue = if (highlighted) Color(0xFFFFA800).copy(alpha = 0.18f) else Color.Transparent,
        animationSpec = tween(durationMillis = 350),
        label = "swarm-picker-halo",
    )
    Surface(color = haloColor, shape = RoundedCornerShape(AuroraRadius.MD.dp)) {
        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp), tint = AuroraColors.hermesMercury)
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        eyebrow,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        title,
                        fontWeight = FontWeight.Bold,
                        color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
            options.forEachIndexed { index, label ->
                ThemePrefsSwarmOptionCard(
                    label = label,
                    selected = index == selectedIndex,
                    useWebsiteBackground = useWebsiteBackground,
                    haptic = haptic,
                ) {
                    onSelect(index)
                }
            }
            Text(
                footer,
                fontSize = 12.sp,
                lineHeight = 15.sp,
                color = if (useWebsiteBackground) Color.White.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ThemePrefsSwarmOptionCard(label: String, selected: Boolean, useWebsiteBackground: Boolean, haptic: HapticFeedback, onClick: () -> Unit) {
    val primaryColor = MaterialTheme.colorScheme.primary
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.MD.dp),
        color = if (selected) primaryColor.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.4f),
        border =
        if (selected) {
            androidx.compose.foundation.BorderStroke(2.dp, primaryColor)
        } else {
            androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
        },
        onClick = {
            onClick()
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        },
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                label,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
                modifier = Modifier.weight(1f),
                color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface,
            )
            if (selected) {
                Surface(modifier = Modifier.size(10.dp), shape = CircleShape, color = primaryColor) {}
            }
        }
    }
}
