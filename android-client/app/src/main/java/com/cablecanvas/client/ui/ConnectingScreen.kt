package com.cablecanvas.client.ui

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularWavyProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ConnectingScreen() {
    val context = LocalContext.current

    // Monet Dynamic Theming (still works perfectly even without the Bitmap!)
    val colorScheme = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else {
        MaterialTheme.colorScheme
    }

    MaterialTheme(colorScheme = colorScheme) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            // Dark Scrim overlay (Makes the spinner visible against bright wallpapers)
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.4f)) // Adjust for darkness
            )

            // Setup Thicker Stroke with ROUNDED caps
            val density = LocalDensity.current
            val thickStroke = remember(density) {
                Stroke(
                    width = with(density) { 8.dp.toPx() },
                    cap = StrokeCap.Round
                )
            }

            // Bigger, Monet-Themed Wavy Spinner
            CircularWavyProgressIndicator(
                modifier = Modifier.size(120.dp),
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.secondary.copy(alpha = 0.3f),
                stroke = thickStroke,
                trackStroke = thickStroke
            )
        }
    }
}
