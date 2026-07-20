package xyz.pieroot.sift

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import xyz.pieroot.sift.ui.theme.SIFTTheme

class MainActivity : ComponentActivity() {
    private var pendingOpenTodoId by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingOpenTodoId = resolveOpenTodoId(intent)
        setContent {
            SIFTTheme {
                SiftApp(
                    openTodoId = pendingOpenTodoId,
                    onOpenTodoHandled = { pendingOpenTodoId = null },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        intent?.let { setIntent(it) }
        pendingOpenTodoId = resolveOpenTodoId(intent)
    }

    private fun resolveOpenTodoId(intent: Intent?): String? {
        return intent?.getStringExtra(EXTRA_OPEN_TODO_ID)?.trim()?.ifEmpty { null }
    }
}