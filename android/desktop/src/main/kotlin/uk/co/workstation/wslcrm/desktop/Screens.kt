package uk.co.workstation.wslcrm.desktop

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.Notice
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection

/** The whole window: the sign-in card, the 2FA step, or the signed-in workspace. */
@Composable
fun RootScreen(session: DesktopSession, environmentName: String) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when (val phase = session.phase) {
            DesktopSession.Phase.Restoring -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            DesktopSession.Phase.SignedOut, is DesktopSession.Phase.TwoFactor -> SignInScreen(session, phase, environmentName)
            is DesktopSession.Phase.SignedIn -> WorkspaceScreen(session, phase)
        }
    }
}

/** Mirrors the iOS sign-in: a brand header card over the form, centred in a wide window. */
@Composable
private fun SignInScreen(session: DesktopSession, phase: DesktopSession.Phase, environmentName: String) {
    val scope = rememberCoroutineScope()
    var identifier by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    val twoFactor = phase as? DesktopSession.Phase.TwoFactor

    Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.padding(vertical = 40.dp, horizontal = 16.dp).widthIn(max = 460.dp).fillMaxWidth()) {
            BrandHeader(environmentName)
            Surface(
                shape = RoundedCornerShape(bottomStart = 22.dp, bottomEnd = 22.dp),
                color = MaterialTheme.colorScheme.surface,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (twoFactor == null) {
                        Text("Sign in", fontSize = 26.sp, fontWeight = FontWeight.Bold)
                        OutlinedTextField(
                            value = identifier, onValueChange = { identifier = it },
                            label = { Text("Email or username") }, placeholder = { Text("name@company.co.uk") },
                            singleLine = true, modifier = Modifier.fillMaxWidth().testTag("login.identifier"),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        )
                        OutlinedTextField(
                            value = password, onValueChange = { password = it }, label = { Text("Password") },
                            singleLine = true, visualTransformation = PasswordVisualTransformation(),
                            modifier = Modifier.fillMaxWidth().testTag("login.password"),
                        )
                    } else {
                        Text("Enter your code", fontSize = 26.sp, fontWeight = FontWeight.Bold)
                        SecondaryText("We sent a 6-digit code to ${twoFactor.email ?: "your email"}. It expires in a few minutes.")
                        OutlinedTextField(
                            value = code, onValueChange = { code = it.filter(Char::isDigit).take(6) },
                            label = { Text("Code") }, singleLine = true,
                            modifier = Modifier.fillMaxWidth().testTag("login.code"),
                        )
                    }
                    session.error?.let { Notice(it, Tone.DANGER) }
                    session.notice?.let { Notice(it, Tone.INFO, icon = Icons.Default.Info) }
                    Button(
                        onClick = {
                            scope.launch {
                                if (twoFactor == null) session.signIn(identifier, password) else session.verify(code)
                            }
                        },
                        enabled = !session.busy && if (twoFactor == null) identifier.isNotBlank() && password.isNotEmpty() else code.length == 6,
                        modifier = Modifier.fillMaxWidth().height(52.dp).testTag("login.submit"),
                        shape = RoundedCornerShape(14.dp),
                    ) {
                        if (session.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Color.White)
                        else Text(if (twoFactor == null) "Sign in" else "Verify", fontWeight = FontWeight.SemiBold)
                    }
                    if (twoFactor != null) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            TextButton(onClick = { session.backToSignIn() }) { Text("Use another account") }
                            TextButton(onClick = { scope.launch { session.resendCode() } }) { Text("Send a new code") }
                        }
                    } else {
                        Spacer(Modifier.height(4.dp))
                        Text("New here?", fontWeight = FontWeight.SemiBold)
                        SecondaryText(
                            "You need an invitation to sign in. Ask your employer, or whoever runs your company's " +
                                "workspace, to invite your email address. Their email has a link to set up your account; then sign in here.",
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BrandHeader(environmentName: String) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp))
            .background(Brush.linearGradient(listOf(Color(0xFF14102E), Color(0xFF1B2A6B), Color(0xFF0D5BC4))))
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Image(
            painterResource("wslcrm.png"), contentDescription = null,
            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(16.dp)),
        )
        Text("Workstation AI-native CRM", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Text("Your whole business, on your desktop.", color = Color.White.copy(alpha = 0.75f))
        if (environmentName != "Production") {
            Surface(shape = RoundedCornerShape(50), color = Color.White.copy(alpha = 0.14f)) {
                Text("$environmentName environment", color = Color.White, fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
            }
        }
    }
}

/**
 * Signed in: who, which workspace, and the modules the server's menu gives this person. Each module
 * still needs its native desktop screen (docs/DESKTOP.md); until then it is listed, never opened as
 * a web page.
 */
@Composable
private fun WorkspaceScreen(session: DesktopSession, phase: DesktopSession.Phase.SignedIn) {
    val scope = rememberCoroutineScope()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(24.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Hello, ${phase.user.displayName}", fontSize = 26.sp, fontWeight = FontWeight.Bold)
                    SecondaryText(phase.workspace?.name ?: "No workspace yet")
                }
                TextButton(onClick = { scope.launch { session.signOut() } }) {
                    Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null)
                    Spacer(Modifier.size(6.dp))
                    Text("Sign out")
                }
            }
        }
        groupedSection(title = "Your modules") {
            if (phase.modules.isEmpty()) {
                GroupedRow(showDivider = false) { SecondaryText("Your workspace hasn't given you any modules yet.") }
            }
            phase.modules.forEachIndexed { index, item ->
                GroupedRow(showDivider = index < phase.modules.lastIndex) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Apps, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.size(12.dp))
                        Text(item.name ?: item.key, Modifier.weight(1f))
                        SecondaryText("Coming to desktop")
                    }
                }
            }
        }
    }
}
