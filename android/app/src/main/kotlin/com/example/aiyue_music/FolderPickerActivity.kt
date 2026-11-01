package com.example.aiyue_music

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts

/**
 * A short-lived bridge around Android's document tree picker.
 *
 * AudioServiceActivity uses the legacy activity result API. Some DocumentsUI
 * versions fail to deliver a cancelled tree selection reliably to it. This
 * ComponentActivity receives both selection and cancellation through the
 * modern API, forwards the result, and always finishes back to the player.
 */
class FolderPickerActivity : ComponentActivity() {
    private var pickerStarted = false

    private val picker = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { response ->
        setResult(response.resultCode, response.data)
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(Activity.RESULT_CANCELED)
        pickerStarted = savedInstanceState?.getBoolean("pickerStarted") ?: false
        if (!pickerStarted) {
            pickerStarted = true
            picker.launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                )
            })
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("pickerStarted", pickerStarted)
        super.onSaveInstanceState(outState)
    }
}
